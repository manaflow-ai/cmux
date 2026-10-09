/// `channel.open` params of kind `terminal`.
public struct TerminalChannelParams: Hashable, Sendable, Codable {
    public var terminal: String
    public var viewport: TerminalViewport
    /// On screen, scene foreground-active and device unlocked.
    public var visible: Bool
    /// Whether this viewer counts toward the shared grid (previews pass false).
    public var counts: Bool
    public var snapshot: TerminalSnapshotSupport

    public init(terminal: String, viewport: TerminalViewport, visible: Bool, counts: Bool, snapshot: TerminalSnapshotSupport) {
        self.terminal = terminal
        self.viewport = viewport
        self.visible = visible
        self.counts = counts
        self.snapshot = snapshot
    }
}
