/// How CmuxLink carries a channel: reliable ordered (interactive or bulk priority) or datagrams.
public enum ChannelClass: String, CaseIterable, Hashable, Sendable, Codable {
    case interactive, bulk, datagram

    /// Datagram channels have no credit and allow seq gaps (loss).
    public var isReliable: Bool { self != .datagram }
}
