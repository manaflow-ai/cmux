/// The DTLS certificate fingerprint an SDP commits to (`a=fingerprint`).
/// Only `sha-256` is accepted; every fingerprint line must agree.
public struct DTLSFingerprint: Sendable, Hashable, CustomStringConvertible {
    /// Upper-case hex pairs joined by `:`.
    public let value: String

    public init?(value: String) {
        let normalized = value.uppercased()
        let pairs = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard pairs.count == 32, pairs.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        self.value = normalized
    }

    /// The single SHA-256 fingerprint of `sdp`, or nil when it has none, uses
    /// another algorithm, or lists different ones.
    public init?(sdp: String) {
        var found: DTLSFingerprint?
        for rawLine in sdp.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("a=fingerprint:") else { continue }
            let rest = line.dropFirst("a=fingerprint:".count).split(separator: " ", maxSplits: 1)
            guard rest.count == 2, rest[0].lowercased() == "sha-256",
                  let fingerprint = DTLSFingerprint(value: String(rest[1]).trimmingCharacters(in: .whitespaces))
            else { return nil }
            if let found, found != fingerprint { return nil }
            found = fingerprint
        }
        guard let found else { return nil }
        self = found
    }

    public var description: String { "sha-256 \(value)" }
}
