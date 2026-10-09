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
    /// The Mac-owned process sleep assertion, when this host exposes it.
    public var caffeine: (any MobileCaffeineControl)?
    /// Values surfaced by the authenticated host status read. The app layer
    /// fills these from its bundle and computer name for each host run.
    public var displayName: String
    public var appVersion: String
    public var appBuild: String

    public init(handlers: MobileChannelHandlers = MobileChannelHandlers(), taskRunner: (any MobileTaskRunner)? = nil,
                taskAttachments: any MobileTaskAttachmentResolver = UnavailableTaskAttachments(), caps: [String] = [],
                allowsTaskDispatch: Bool = false, allowsTerminalSpawn: Bool = false,
                caffeine: (any MobileCaffeineControl)? = nil,
                displayName: String = "", appVersion: String = "0", appBuild: String = "0") {
        self.handlers = handlers
        self.taskRunner = taskRunner
        self.taskAttachments = taskAttachments
        self.caps = caps
        self.allowsTaskDispatch = allowsTaskDispatch
        self.allowsTerminalSpawn = allowsTerminalSpawn
        self.caffeine = caffeine
        self.displayName = displayName
        self.appVersion = appVersion
        self.appBuild = appBuild
    }

    /// The host configuration for this Mac with these features.
    func configuration(hostID: String, accountUserID: String) -> MobileHostConfiguration {
        var caps = MobileHostConfiguration.defaultCaps
        for cap in self.caps where !caps.contains(cap) { caps.append(cap) }
        return MobileHostConfiguration(hostID: hostID, accountUserID: accountUserID, allowsTerminalSpawn: allowsTerminalSpawn,
                                       allowsTaskDispatch: allowsTaskDispatch, caps: caps,
                                       displayName: displayName, appVersion: appVersion, appBuild: appBuild)
    }
}
