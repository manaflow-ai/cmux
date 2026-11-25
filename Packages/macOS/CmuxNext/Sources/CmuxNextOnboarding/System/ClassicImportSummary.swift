import Foundation

/// What `workspace.importClassic` opened and what it left in classic.
public struct ClassicImportSummary: Equatable, Sendable {
    public var opened = 0
    /// Cloud VM workspaces: cmux-next cannot reach a classic VM.
    public var leftCloudVMs = false
    /// SSH workspaces whose host did not connect.
    public var leftSSH = false
    /// Scrollback of SSH terminals: their shells run on the host, where this
    /// Mac's replay file is not.
    public var leftSSHScrollback = false
    /// Tabs nothing here shows (a simulator, a project), and markdown or file preview tabs whose file is gone.
    public var leftTabs = false
    /// Classic workspaces an earlier run brought over that are still open here.
    public var alreadyHere = 0

    public init() {}

    /// Adds what `other` (one workspace's import) opened and left.
    public mutating func merge(_ other: ClassicImportSummary) {
        opened += other.opened
        leftCloudVMs = leftCloudVMs || other.leftCloudVMs
        leftSSH = leftSSH || other.leftSSH
        leftSSHScrollback = leftSSHScrollback || other.leftSSHScrollback
        leftTabs = leftTabs || other.leftTabs
        alreadyHere += other.alreadyHere
    }
}
