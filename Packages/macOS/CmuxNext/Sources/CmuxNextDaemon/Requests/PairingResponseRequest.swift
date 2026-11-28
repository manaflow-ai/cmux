import Foundation

extension PairingResponseRequest {
    /// The reply is empty; `pairing-response` answers `ok` and nothing else.
    public struct Response: Decodable, Sendable {}
}
