import Foundation
import CmuxNextCompat
import os

/// Where the daemon listens, as printed by `server ensure`.
public struct DaemonEndpoint: Hashable, Sendable {
    public var socketPath: String
    public var pid: Int32?
    public var generation: DaemonGeneration?
    /// Connect through this child process instead of `socketPath`
    /// (``DaemonBridge``: a paired server's owner session through `cmux link
    /// dial`). `socketPath` then only names what to watch for changes.
    public var bridge: DaemonBridge?

    public init(socketPath: String, pid: Int32? = nil, generation: DaemonGeneration? = nil, bridge: DaemonBridge? = nil) {
        self.socketPath = socketPath
        self.pid = pid
        self.generation = generation
        self.bridge = bridge
    }
}

/// The lists derived from each ``DaemonCapability``'s ``DaemonCapability/tier``. The cases, their wire names
/// and tiers are cmux-tui/spec/gui-capabilities.json, from which DaemonCapabilitiesPlugin writes the enum on
/// every build (scripts/cmux-next/gen-daemon-capabilities.py).
extension DaemonCapability {
    /// The minimum handshake surface served by the Native guest owner. Keep
    /// this separate from ``required``: Native does not implement the GUI's
    /// viewport/layout/attachment controls.
    public static let nativeRemoteRequired: [String] = [
        workspaceRegistry.rawValue,
        "layout-delta-v1",
        sessionIdentity.rawValue,
        conversationTabs.rawValue,
        agentSessionTabs.rawValue,
        agentSessionStart.rawValue,
        agentSessionAttach.rawValue,
    ]

    /// The wire names of the capabilities the GUI cannot work without.
    public static let required: [String] = names(in: .required)

    /// Capabilities the bundled daemon must serve. The bundled cmux-tui is
    /// built from this checkout's own cmux-tui tree
    /// (scripts/cmux-next/pin-cmux-tui.sh), and
    /// scripts/cmux-next/check-daemon-capabilities.sh fails the build when it
    /// does not serve one of these or `required`. The GUI still checks each
    /// with `DaemonIdentity.supports`, for remote and older daemons.
    public static let optional: [String] = names(in: .optional)

    /// App code waiting for a daemon half that no branch has yet. Each
    /// feature shows disabled with its reason (or refuses with it) while the
    /// bundled daemon lacks the capability. The list only shrinks
    /// (DaemonCapabilityExportTests): new app features land with their
    /// daemon half, and check-daemon-capabilities.sh fails once the bundled
    /// daemon serves an entry, so it moves to `optional`.
    public static let unservedByBundledDaemon: [String] = names(in: .unservedByBundledDaemon)

    /// Served only by the local (home) daemon; a remote machine's daemon never needs them.
    public static let homeOnly: [String] = names([.profiles, .personalTerminals, .browserProfiles, .bookmarks,
                                                  .localConversations, .sessionIcon])
    /// Written to the local daemon's personal rows instead of each machine's
    /// daemon once the local daemon serves `profiles-v1`.
    public static let personalOnHome: [String] = names([.workspaceGroups, .savedTabGroups])

    /// Whether the bundled daemon (this tree's cmux-tui) serves `capability`:
    /// a daemon without it is an older build, and restarting cmux updates it.
    public static func isServedByBundledDaemon(_ capability: String) -> Bool {
        guard let known = DaemonCapability(rawValue: capability) else { return false }
        return known.tier != .unservedByBundledDaemon
    }

    /// Echoed through `set-client-info` so the daemon enables additive shapes.
    /// `terminalFrontendShellIntegration` is not in it: only a connection
    /// that resolves the integration echoes it (`handshakeCapabilities`).
    /// `sharedSizing` is not either: a terminal attachment that names its device adds it
    /// (`TerminalAttachment.attach(device:)`); other connections only read it from `identify`.
    /// `placementShift` only with the sidebar document (`handshakeCapabilities`).
    public static let advertised: [String] = (required + optional + unservedByBundledDaemon).filter {
        !notAdvertised.contains($0)
    }
    private static let notAdvertised: Set<String> = Set(names([.terminalFrontendShellIntegration, .placementShift,
                                                               .sharedSizing, .agentSessionPresence]))

    private static func names(_ capabilities: [DaemonCapability]) -> [String] { capabilities.map(\.rawValue) }
    private static func names(in tier: Tier) -> [String] { names(allCases.filter { $0.tier == tier }) }
}
