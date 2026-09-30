public import Foundation
import Network

/// The loopback rule of plans/cmux-next/remote-localhost.md section 2, from
/// the literal host only (never DNS): `localhost`, names under `.localhost`,
/// `127.0.0.0/8`, `::1` (bracketed or not) and IPv4-mapped loopback. The
/// cmux-tui daemon applies the same rule (`classify_target`) and refuses
/// everything else.
public enum LoopbackHost {
    /// True when `host` goes to the tab's machine.
    public static func isLoopback(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 255 else { return false }
        if host.hasPrefix("[") {
            guard host.hasSuffix("]"), let address = IPv6Address(String(host.dropFirst().dropLast())) else { return false }
            return isLoopback(address)
        }
        if host.contains(":") {
            guard let address = IPv6Address(host) else { return false }
            return isLoopback(address)
        }
        if let address = strictIPv4(host) { return address[0] == 127 }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard name.utf8.count <= 253 else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.last == "localhost" else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
        }
    }

    /// True for a URL whose host is a loopback name or literal.
    public static func isLoopback(url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false) else { return false }
        return isLoopback(host)
    }

    /// True for an address a remote-localhost page must never reach on this
    /// Mac (section 2, second rule): loopback and unspecified.
    static func isLocalOnly(_ address: any IPAddress) -> Bool {
        if let v4 = address as? IPv4Address {
            return v4.isLoopback || v4 == .any || v4.rawValue.first == 0
        }
        if let v6 = address as? IPv6Address {
            if v6.isLoopback || v6 == .any { return true }
            if let mapped = v6.asIPv4 { return mapped.isLoopback || mapped == .any }
        }
        return false
    }

    private static func isLoopback(_ address: IPv6Address) -> Bool {
        if address.isLoopback { return true }
        if let mapped = address.asIPv4 { return mapped.rawValue.first == 127 }
        return false
    }

    /// Dotted-quad only: `127.1`, `0x7f.0.0.1` and `2130706433` are not
    /// addresses here (the daemon rejects them too).
    private static func strictIPv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  part.count == 1 || part.first != "0", let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return bytes
    }
}
