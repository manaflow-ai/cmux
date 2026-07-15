import Foundation

/// Classifies hosts that should not receive a public-HTTP security warning.
struct BrowserSecurityHostClassifier {
    func isLocalOrPrivateHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "localhost" || normalized.hasSuffix(".localhost") {
            return true
        }
        if normalized == "::1" || normalized == "0:0:0:0:0:0:0:1" {
            return true
        }
        if isPrivateOrLoopbackIPv4(normalized) {
            return true
        }
        return isPrivateOrLoopbackIPv6(normalized)
    }

    private func isPrivateOrLoopbackIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let values = octets.compactMap { Int($0) }
        guard values.count == 4, values.allSatisfy({ (0...255).contains($0) }) else { return false }
        if values[0] == 127 { return true }
        if values[0] == 10 { return true }
        if values[0] == 192 && values[1] == 168 { return true }
        if values[0] == 172 && (16...31).contains(values[1]) { return true }
        if values[0] == 169 && values[1] == 254 { return true }
        // CGNAT 100.64.0.0/10 includes Tailscale addresses.
        if values[0] == 100 && (64...127).contains(values[1]) { return true }
        return false
    }

    private func isPrivateOrLoopbackIPv6(_ host: String) -> Bool {
        guard host.contains(":") else { return false }
        if host.hasPrefix("::ffff:") {
            return isPrivateOrLoopbackIPv4(String(host.dropFirst("::ffff:".count)))
        }
        guard let firstHextetText = host.split(separator: ":", omittingEmptySubsequences: false).first,
              let firstHextet = UInt16(firstHextetText, radix: 16)
        else {
            return false
        }
        if (0xFC00...0xFDFF).contains(firstHextet) {
            return true
        }
        return (0xFE80...0xFEBF).contains(firstHextet)
    }
}
