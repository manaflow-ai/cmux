public import Foundation

/// A device or host WireGuard public key (X25519, 32 bytes). Hosts pin the
/// device key in their trust store; devices pin the host key at pairing.
public struct WireGuardPublicKey: Sendable, Hashable, CustomStringConvertible {
    public static let length = 32

    public let rawRepresentation: Data

    /// Returns nil unless `rawRepresentation` is 32 bytes.
    public init?(rawRepresentation: Data) {
        guard rawRepresentation.count == Self.length else { return nil }
        self.rawRepresentation = Data(rawRepresentation)
    }

    /// Standard (wg-quick) or URL-safe base64, padding optional.
    public init?(base64: String) {
        var text = base64.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text.append("=") }
        guard let data = Data(base64Encoded: text) else { return nil }
        self.init(rawRepresentation: data)
    }

    public var base64: String { rawRepresentation.base64EncodedString() }

    public var description: String { "WireGuardPublicKey(\(base64))" }

    var bytes: [UInt8] { [UInt8](rawRepresentation) }
}
