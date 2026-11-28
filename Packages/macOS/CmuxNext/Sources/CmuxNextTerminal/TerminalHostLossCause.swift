/// What a lost host left as evidence (tab `end.cause`, cx-0tgl): the first
/// signal it recorded and who sent it, and whether it had panicked. The
/// banner names it after the reason, in localized words.
public nonisolated struct TerminalHostLossCause: Sendable, Equatable {
    /// Conventional signal name (`SIGTERM`).
    public var signal: String?
    public var senderPid: Int64?
    /// The sender's process name, when it still ran when recorded.
    public var senderName: String?
    public var panicked: Bool

    public init(signal: String? = nil, senderPid: Int64? = nil, senderName: String? = nil,
                panicked: Bool = false) {
        self.signal = signal
        self.senderPid = senderPid
        self.senderName = senderName
        self.panicked = panicked
    }
}
