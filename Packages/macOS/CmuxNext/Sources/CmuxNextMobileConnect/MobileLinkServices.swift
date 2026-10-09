public import CmuxMobileHost
public import Foundation

/// The phone link's services beyond workspaces and terminals, supplied by
/// the app (D1b): C4 files, C13 git, C2 browser pages, C3 remote desktop,
/// C14 tunnels and simulators, C8 tasks. Each is optional; a missing one is
/// refused like before. Both spawn gates stay off by default.
public struct MobileLinkServices: Sendable {
    /// The display name of a paired device for an install id (the trust store's).
    public typealias DeviceNames = @Sendable (_ install: String) async -> String?

    /// The Mac user's home: C4 roots must be inside it, the inbox is under it.
    public var homeDirectory: URL
    public var browserPages: (any BrowserPageHost)?
    /// Makes the `rd` handler (its consent panel and indicator name devices).
    public var remoteDesktop: (@Sendable (_ names: @escaping DeviceNames) -> any MobileChannelHandler)?
    public var simulators: (any SimulatorCaptureHost)?
    /// The Mac's tunnel allowlist (a Mac setting, empty by default).
    public var allowedPorts: [UInt16]
    /// This Mac's acpmux socket, when acpmux exists here; nil: no task runner.
    public var acpmuxSocketPath: (@Sendable () async -> String?)?
    /// This Mac's stable install id as agent tabs record it, and its name.
    public var agentHost: String?
    public var agentHostName: String?
    /// The agent-home base (`~/Library/Application Support/cmux/agent-home`).
    public var agentHomes: URL?
    public var allowsTaskDispatch: Bool
    public var allowsTerminalSpawn: Bool

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                browserPages: (any BrowserPageHost)? = nil,
                remoteDesktop: (@Sendable (_ names: @escaping DeviceNames) -> any MobileChannelHandler)? = nil,
                simulators: (any SimulatorCaptureHost)? = nil, allowedPorts: [UInt16] = [],
                acpmuxSocketPath: (@Sendable () async -> String?)? = nil, agentHost: String? = nil,
                agentHostName: String? = nil, agentHomes: URL? = nil,
                allowsTaskDispatch: Bool = false, allowsTerminalSpawn: Bool = false) {
        self.homeDirectory = homeDirectory
        self.browserPages = browserPages
        self.remoteDesktop = remoteDesktop
        self.simulators = simulators
        self.allowedPorts = allowedPorts
        self.acpmuxSocketPath = acpmuxSocketPath
        self.agentHost = agentHost
        self.agentHostName = agentHostName
        self.agentHomes = agentHomes
        self.allowsTaskDispatch = allowsTaskDispatch
        self.allowsTerminalSpawn = allowsTerminalSpawn
    }
}
