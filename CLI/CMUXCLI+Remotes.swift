import Darwin
import Foundation

// `cmux remotes` (alias `remote`): manage the team's device-registry routes so
// remote Macs show up in the iOS app's device list and the phone can attach.
// The CLI is presentation only; each verb maps to one `remotes.*` socket method
// handled by the app's `RemotesClient` (the single registry-mutation path).
extension CMUXCLI {
    static let remotesUsage = """
        Usage: cmux remotes <list|add|remove> [options]

        Manage the remote Macs in your team's cmux device registry. Added remotes
        appear in your iOS app's device list and the phone can attach to them.

          cmux remotes list [--json]
              List your team's registered remotes (name, deviceId, routes, tag, last seen).

          cmux remotes add <name> --route <host:port> [--route <host:port> ...] [--tag <tag>] [--json]
              Register or update a remote with one or more attach routes. Idempotent on
              <name>: re-adding the same name updates its routes. <host> must be a Tailscale
              address the phone can authenticate to: a 100.64.x.x-100.127.x.x (CGNAT) IP or a
              *.ts.net MagicDNS name. Plain LAN IPs, hostnames, and loopback are rejected
              because they would show in the device list but fail to connect from iOS.

          cmux remotes remove <name-or-deviceId> [--json]
              Remove a remote you registered from the device registry.

        Examples:
          cmux remotes add my-studio --route 100.64.1.2:51001
          cmux remotes add my-studio --route my-studio.tailnet.ts.net:51001 --tag stable
          cmux remotes list --json
          cmux remotes remove my-studio
        """

    func runRemotesCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        let sub = commandArgs.first?.lowercased() ?? "list"
        let rest = Array(commandArgs.dropFirst())

        switch sub {
        case "help", "--help", "-h":
            print(Self.remotesUsage)

        case "list", "ls":
            let response = try client.sendV2(method: "remotes.list")
            if jsonOutput {
                print(jsonString(response))
                return
            }
            let remotes = (response["remotes"] as? [[String: Any]]) ?? []
            if remotes.isEmpty {
                print("No remotes. Add one: cmux remotes add <name> --route <host:port>")
                return
            }
            printRemotesTable(remotes)

        case "add":
            let (routeValues, rem0) = parseRepeatedOption(rest, name: "--route")
            let (tagOpt, rem1) = parseOption(rem0, name: "--tag")
            let positionals = rem1.filter { !$0.hasPrefix("-") }
            guard let name = positionals.first, !name.isEmpty else {
                throw CLIError(message: """
                    remotes add requires a name.

                    \(Self.remotesUsage)
                    """)
            }
            if positionals.count > 1 {
                throw CLIError(message: "remotes add: unexpected argument '\(positionals[1])'. Pass routes with --route host:port.")
            }
            guard !routeValues.isEmpty else {
                throw CLIError(message: """
                    remotes add requires at least one --route host:port.

                      cmux remotes add \(name) --route 100.64.1.2:51001
                    """)
            }
            // Pre-validate routes locally for a fast, clear error before the
            // round-trip. The app and the web API enforce the same rules as the
            // trust boundary, so a malformed/loopback route never lands in the
            // registry even if this check is bypassed.
            for route in routeValues {
                try validateRemoteRouteToken(route)
            }
            var params: [String: Any] = ["name": name, "routes": routeValues]
            if let tagOpt, !tagOpt.isEmpty { params["tag"] = tagOpt }
            let response = try client.sendV2(method: "remotes.add", params: params)
            if jsonOutput {
                print(jsonString(response))
                return
            }
            let deviceId = (response["deviceId"] as? String) ?? "?"
            print("OK \(name)")
            print("  deviceId: \(deviceId)")
            print("  routes:   \(routeValues.joined(separator: ", "))")
            if let tagOpt, !tagOpt.isEmpty { print("  tag:      \(tagOpt)") }

        case "remove", "rm", "delete":
            let positionals = rest.filter { !$0.hasPrefix("-") }
            guard let target = positionals.first, !target.isEmpty else {
                throw CLIError(message: """
                    remotes remove requires a name or deviceId.

                      cmux remotes remove <name-or-deviceId>

                    List remotes: cmux remotes list
                    """)
            }
            let response = try client.sendV2(method: "remotes.remove", params: ["target": target])
            if jsonOutput {
                print(jsonString(response))
                return
            }
            print("OK removed \(target)")

        default:
            throw CLIError(message: """
                Unknown remotes subcommand: \(sub)

                \(Self.remotesUsage)
                """)
        }
    }

    /// Lightweight client-side host:port validation for `remotes add --route`.
    /// Mirrors the app/server rules (host:port shape, port range, loopback
    /// refusal) so the user gets a fast, clear message; the authoritative check
    /// still runs in the app (CmxLoopbackHost) and the web API.
    func validateRemoteRouteToken(_ raw: String) throws {
        let (host, port) = try splitRemoteRouteToken(raw)
        guard let portValue = Int(port), (1...65535).contains(portValue) else {
            throw CLIError(message: "Invalid route '\(raw)': port must be 1-65535. Use host:port, e.g. 100.64.1.2:51001.")
        }
        if remoteHostIsLoopback(host) {
            throw CLIError(message: """
                Refusing to add a loopback remote (\(host)). A phone that dials localhost / 127.0.0.1 / ::1 dials \
                itself, so the remote would never be reachable. Use the Mac's Tailscale address instead \
                (a 100.64.x.x-100.127.x.x IP or a *.ts.net name).
                """)
        }
    }

    /// Split a `host:port` token into host and port, accepting bracketed IPv6
    /// (`[::1]:51001`). Bare unbracketed IPv6 is rejected as ambiguous.
    func splitRemoteRouteToken(_ raw: String) throws -> (host: String, port: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: "Invalid route '\(raw)'. Use host:port, e.g. 100.64.1.2:51001.")
        }
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else {
                throw CLIError(message: "Invalid route '\(raw)': unterminated IPv6 bracket. Use [::1]:port form.")
            }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let after = trimmed[trimmed.index(after: close)...]
            guard after.hasPrefix(":") else {
                throw CLIError(message: "Invalid route '\(raw)': missing :port after IPv6 address.")
            }
            let host2 = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host2.isEmpty else {
                throw CLIError(message: "Invalid route '\(raw)': empty host.")
            }
            return (host2, String(after.dropFirst()))
        }
        guard let lastColon = trimmed.lastIndex(of: ":") else {
            throw CLIError(message: "Invalid route '\(raw)': missing :port. Use host:port, e.g. 100.64.1.2:51001.")
        }
        let host = String(trimmed[trimmed.startIndex..<lastColon]).trimmingCharacters(in: .whitespacesAndNewlines)
        let port = String(trimmed[trimmed.index(after: lastColon)...])
        if host.contains(":") {
            throw CLIError(message: "Invalid route '\(raw)': bracket IPv6 addresses as [<ipv6>]:port.")
        }
        guard !host.isEmpty else {
            throw CLIError(message: "Invalid route '\(raw)': empty host.")
        }
        return (host, port)
    }

    /// Whether `host` is a loopback host the phone could never dial. A small
    /// CLI-side mirror of the app's `CmxLoopbackHost` (the CLI target does not
    /// link CMUXMobileCore); the app and server remain the authoritative check.
    func remoteHostIsLoopback(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 {
            host = String(host.dropFirst().dropLast())
        }
        if let zone = host.firstIndex(of: "%") {
            host = String(host[..<zone])
        }
        if host.hasSuffix("."), host.count > 1 {
            host = String(host.dropLast())
        }
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }

        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 {
            let firstOctet = UInt8(truncatingIfNeeded: UInt32(bigEndian: v4.s_addr) >> 24)
            return firstOctet == 127 || firstOctet == 0
        }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            guard bytes.count == 16 else { return false }
            if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] <= 1 { return true }
            let prefixZero = bytes[0..<10].allSatisfy { $0 == 0 }
            let isMapped = prefixZero && bytes[10] == 0xFF && bytes[11] == 0xFF
            let isCompatible = prefixZero && bytes[10] == 0 && bytes[11] == 0
            if isMapped || isCompatible {
                return bytes[12] == 127 || bytes[12] == 0
            }
        }
        return false
    }

    private func printRemotesTable(_ remotes: [[String: Any]]) {
        for remote in remotes {
            let name = Self.sanitizeForTerminal((remote["displayName"] as? String) ?? "(unnamed)")
            let deviceId = (remote["deviceId"] as? String) ?? "?"
            let shortId = String(deviceId.prefix(8))
            let routes = (remote["routes"] as? [[String: Any]]) ?? []
            let routeStrings = routes.compactMap { route -> String? in
                guard let host = route["host"] as? String else { return nil }
                let port = (route["port"] as? Int) ?? Int((route["port"] as? Double) ?? 0)
                return "\(Self.sanitizeForTerminal(host)):\(port)"
            }
            let routeText = routeStrings.isEmpty ? "(no routes)" : routeStrings.joined(separator: ", ")
            let tag = (remote["tag"] as? String).map { " tag=\(Self.sanitizeForTerminal($0))" } ?? ""
            let lastSeen = (remote["lastSeen"] as? String).map { " lastSeen=\(Self.sanitizeForTerminal($0))" } ?? ""
            print("\(name)  [\(shortId)]  \(routeText)\(tag)\(lastSeen)")
        }
    }

    /// Strip control characters (ANSI escapes, CR/LF, etc.) before printing a
    /// registry string in the `remotes list` table. A `displayName` is set by a
    /// team member via `remotes add`, so without this a member could embed
    /// terminal escape sequences that render in another member's terminal when
    /// they run `remotes list`. Replaces control chars with U+FFFD; `--json`
    /// output is unaffected (it goes through the JSON encoder).
    static func sanitizeForTerminal(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            (scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format)
                ? Character("\u{FFFD}")
                : Character(scalar)
        })
    }
}
