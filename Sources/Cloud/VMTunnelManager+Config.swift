import Darwin
import Foundation

extension VMTunnelManager {
    /// Completes the server template with this build's private key and routes.
    ///
    /// When the network prefixes are known, routes are installed as macOS
    /// interface-scoped entries.  `wg-quick`'s default unscoped route insertion
    /// rejects a second tunnel for the same account with `EEXIST`; `Table = off`
    /// plus these hooks lets each utun own an independent entry instead.
    static func completedConfig(
        _ config: String,
        privateKey: String,
        allowedIPs: [String] = []
    ) throws -> String {
        var lines = config.components(separatedBy: "\n")
        let interfaceStart = try sectionStart("[Interface]", in: lines)
        var interfaceEnd = sectionEnd(after: interfaceStart, in: lines)

        if let privateKeyIndex = firstKeyIndex(
            named: "privatekey",
            in: interfaceStart..<interfaceEnd,
            lines: lines
        ) {
            lines[privateKeyIndex] = "PrivateKey = \(privateKey)"
        } else {
            lines.insert("PrivateKey = \(privateKey)", at: interfaceStart + 1)
            interfaceEnd += 1
        }

        guard !allowedIPs.isEmpty else {
            return lines.joined(separator: "\n")
        }

        let routes = try normalizedRoutes(allowedIPs)
        let peerStart = try sectionStart("[Peer]", in: lines)
        let peerEnd = sectionEnd(after: peerStart, in: lines)
        let allowedIPsLine = "AllowedIPs = \(routes.joined(separator: ", "))"
        if let allowedIPsIndex = firstKeyIndex(
            named: "allowedips",
            in: peerStart..<peerEnd,
            lines: lines
        ) {
            lines[allowedIPsIndex] = allowedIPsLine
        } else {
            lines.insert(allowedIPsLine, at: peerStart + 1)
        }

        // Recompute bounds after the peer edit.  The route directives must live
        // in `[Interface]`; wg-quick only parses hook keys in that section.
        interfaceEnd = sectionEnd(after: interfaceStart, in: lines)
        if let tableIndex = firstKeyIndex(
            named: "table",
            in: interfaceStart..<interfaceEnd,
            lines: lines
        ) {
            lines[tableIndex] = "Table = off"
        } else {
            lines.insert("Table = off", at: interfaceEnd)
            interfaceEnd += 1
        }

        let hooks = routes.flatMap { route in
            [
                routeHook(key: "PostUp", action: "add", route: route),
                routeHook(key: "PreDown", action: "delete", route: route),
            ]
        }
        let existing = Set(lines[interfaceStart..<interfaceEnd])
        let newHooks = hooks.filter { !existing.contains($0) }
        guard !newHooks.isEmpty else {
            return lines.joined(separator: "\n")
        }
        lines.insert(contentsOf: newHooks, at: interfaceEnd)
        return lines.joined(separator: "\n")
    }

    private static func sectionStart(_ header: String, in lines: [String]) throws -> Int {
        let normalizedHeader = header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedHeader
        }) else {
            throw TunnelError.configMalformed("no \(header) section in server config")
        }
        return index
    }

    private static func sectionEnd(after start: Int, in lines: [String]) -> Int {
        let nextSection = lines[(start + 1)...].firstIndex {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
        }
        return nextSection ?? lines.count
    }

    private static func firstKeyIndex(
        named name: String,
        in range: Range<Int>,
        lines: [String]
    ) -> Int? {
        let normalizedName = name.lowercased()
        return lines[range].firstIndex { line in
            line.split(separator: "=", maxSplits: 1).first
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() == normalizedName }
                ?? false
        }
    }

    private static func normalizedRoutes(_ values: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(values.count)
        for raw in values {
            let route = try normalizedRoute(raw)
            if seen.insert(route).inserted {
                result.append(route)
            }
        }
        return result
    }

    private static func normalizedRoute(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = value.lastIndex(of: "/"), slash > value.startIndex else {
            throw TunnelError.configMalformed("invalid network route \(value)")
        }
        let address = String(value[..<slash])
        let prefixText = String(value[value.index(after: slash)...])
        guard !address.isEmpty,
              !prefixText.isEmpty,
              prefixText.allSatisfy(\.isNumber),
              let prefix = Int(prefixText) else {
            throw TunnelError.configMalformed("invalid network route \(value)")
        }

        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            guard (0...32).contains(prefix) else {
                throw TunnelError.configMalformed("invalid IPv4 route prefix \(value)")
            }
            return "\(address)/\(prefix)"
        }

        var ipv6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            guard (0...128).contains(prefix) else {
                throw TunnelError.configMalformed("invalid IPv6 route prefix \(value)")
            }
            return "\(address)/\(prefix)"
        }

        throw TunnelError.configMalformed("invalid network route \(value)")
    }

    private static func routeHook(key: String, action: String, route: String) -> String {
        let family = route.contains(":") ? "inet6" : "inet"
        let quotedRoute = shellQuote(route)
        if action == "add" {
            // A stale route for this same utun is harmless (for example after
            // a killed wg-quick process).  Treat that one case as success,
            // but let a real route-install failure abort wg-quick's bring-up.
            return "\(key) = /sbin/route -q -n add -\(family) \(quotedRoute) -interface %i -ifscope %i || /sbin/route -n get -\(family) -ifscope %i \(quotedRoute) 2>&1 | /usr/bin/grep -q 'interface: %i'"
        }
        return "\(key) = /sbin/route -q -n delete -\(family) -ifscope %i \(quotedRoute) || true"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
