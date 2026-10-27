import Foundation

/// `pairing-response` (cmux-tui spec/transports.md "Authentication and Pairing"): approves or
/// denies one WebSocket pairing the daemon announced with `pairing-requested`. Only the verified
/// app (the `frontend` actor) may approve; any other local connection may only deny.
public struct PairingResponseRequest: DaemonRequest {
    public struct Response: Decodable, Sendable {}
    public static let commandName: DaemonCommandName = "pairing-response"
    public var request: UInt64
    public var approve: Bool

    public init(request: UInt64, approve: Bool) {
        self.request = request
        self.approve = approve
    }
}
