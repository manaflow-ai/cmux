import CmuxMobileWire

/// One viewer's attach (terminal channel params plus who the viewer is, for
/// presence and input attribution).
public struct MobileTerminalAttachRequest: Hashable, Sendable {
    public var terminal: String
    public var viewport: TerminalViewport
    public var visible: Bool
    public var counts: Bool
    /// GHOSTSNP versions the viewer restores; empty means byte replay.
    public var snapshotVersions: [Int]
    public var viewer: MobileDevicePrincipal

    public init(terminal: String, viewport: TerminalViewport, visible: Bool, counts: Bool, snapshotVersions: [Int],
                viewer: MobileDevicePrincipal) {
        self.terminal = terminal
        self.viewport = viewport
        self.visible = visible
        self.counts = counts
        self.snapshotVersions = snapshotVersions
        self.viewer = viewer
    }
}
