/// The host a dialer connects to. Carriers resolve it to their own
/// addressing (signaling room, overlay address, dialed address).
public struct LinkPeer: Sendable, Hashable {
    /// The host's stable id (device registry, pairing record).
    public var hostID: String
    /// Carrier-specific hints, for example a user-entered address.
    public var hints: [String: String]

    public init(hostID: String, hints: [String: String] = [:]) {
        self.hostID = hostID
        self.hints = hints
    }
}
