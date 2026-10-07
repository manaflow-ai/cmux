public import CmuxMobileHost

/// What the Mac serves beyond workspaces and terminals: the channel and
/// read handlers (files, git, browser, remote desktop, tunnels,
/// simulators), the task runner, the caps they add, and the two spawn gates,
/// which stay off until a live verification (b5-mac-host.md 3, c8-composer.md 3).
public struct MobileHostFeatures: Sendable {
    public var handlers: MobileChannelHandlers
    public var taskRunner: (any MobileTaskRunner)?
    public var taskAttachments: any MobileTaskAttachmentResolver
    /// Added to `MobileHostConfiguration.defaultCaps` (for example `MobileGit.cap`).
    public var caps: [String]
    public var allowsTaskDispatch: Bool
    public var allowsTerminalSpawn: Bool

    public init(handlers: MobileChannelHandlers = MobileChannelHandlers(), taskRunner: (any MobileTaskRunner)? = nil,
                taskAttachments: any MobileTaskAttachmentResolver = UnavailableTaskAttachments(), caps: [String] = [],
                allowsTaskDispatch: Bool = false, allowsTerminalSpawn: Bool = false) {
        self.handlers = handlers
        self.taskRunner = taskRunner
        self.taskAttachments = taskAttachments
        self.caps = caps
        self.allowsTaskDispatch = allowsTaskDispatch
        self.allowsTerminalSpawn = allowsTerminalSpawn
    }

    /// The host configuration for this Mac with these features.
    func configuration(hostID: String, accountUserID: String) -> MobileHostConfiguration {
        var caps = MobileHostConfiguration.defaultCaps
        for cap in self.caps where !caps.contains(cap) { caps.append(cap) }
        return MobileHostConfiguration(hostID: hostID, accountUserID: accountUserID, allowsTerminalSpawn: allowsTerminalSpawn,
                                       allowsTaskDispatch: allowsTaskDispatch, caps: caps)
    }
}
