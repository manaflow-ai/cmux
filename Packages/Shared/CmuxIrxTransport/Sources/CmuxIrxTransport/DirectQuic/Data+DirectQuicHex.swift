import Foundation

extension Data {
    /// Lowercase hex, the module's rendering of Ed25519 endpoint IDs.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
