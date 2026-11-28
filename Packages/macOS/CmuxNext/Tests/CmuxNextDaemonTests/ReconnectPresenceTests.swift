@testable import CmuxNextDaemon
import Foundation
import Testing

/// hq#19373 (Leo, ask c-ea62b204f6: "a graceful if not imperceptible state transition all around"): a drop and
/// reconnect to the same daemon used to blank every tab's agent presence until that agent's next hook event. A
/// daemon that says `agent-presence-replay-v1` replays every terminal's presence first on `subscribe`, so the
/// store keeps what it shows through the drop; any other connect starts blank.
@MainActor @Suite struct ReconnectPresenceTests {
    private static let surface = SurfaceID(rawValue: 10)
    private static let replay = [DaemonCapability.agentPresenceReplay.rawValue]

    private static func tree(generation: DaemonGeneration = "boot-a") -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: surface, title: "agent")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 2), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(generation: generation, registryID: "reg",
                          workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 3), key: nil, name: "w", screens: [screen])])
    }

    private static func connect(_ store: DaemonStore, serial: UInt64, generation: String = "boot-a",
                                capabilities: [String] = replay) {
        let identity = DaemonIdentity(capabilities: capabilities, registryID: "reg",
                                      generation: DaemonGeneration(rawValue: generation))
        let envelope = DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: serial, index: 0),
                                           event: .connected(identity, generationChanged: false), sourceID: UUID())
        _ = store.apply(batch: [envelope])
    }

    private static func editing(_ store: DaemonStore) -> DaemonStore {
        connect(store, serial: 1)
        store.apply(snapshot: tree())
        _ = store.apply(.agentPresenceChanged(AgentPresence(surface: surface, activity: .editing, agent: "claude", path: "/r/a.rs")))
        return store
    }

    private static func presence(_ store: DaemonStore) -> AgentPresence? { store.index.tabsBySurface[surface]?.presence }

    @Test func presenceStaysThroughADropAndAReconnectToTheSameDaemon() {
        let store = Self.editing(DaemonStore())
        _ = store.apply(.disconnected(reason: "link dropped"))
        #expect(Self.presence(store)?.activity == .editing, "the drop blanked presence")
        Self.connect(store, serial: 2)
        store.apply(snapshot: Self.tree())
        #expect(Self.presence(store)?.activity == .editing, "a reconnect to the same daemon blanked presence")
        // The replay then corrects it: this agent stopped while the link was down.
        _ = store.apply(.agentPresenceChanged(AgentPresence(surface: Self.surface, activity: nil)))
        #expect(Self.presence(store) == nil)
    }

    @Test func anotherDaemonGenerationStartsBlank() {
        let store = Self.editing(DaemonStore())
        _ = store.apply(.disconnected(reason: "daemon restarted"))
        Self.connect(store, serial: 2, generation: "boot-b")
        #expect(Self.presence(store) == nil, "presence from another daemon was kept")
    }

    @Test func aDaemonThatDoesNotReplayPresenceStartsBlank() {
        let store = Self.editing(DaemonStore())
        _ = store.apply(.disconnected(reason: "link dropped"))
        Self.connect(store, serial: 2, capabilities: [])
        #expect(Self.presence(store) == nil, "kept presence nothing will correct")
    }

    @Test func aShutdownClearsPresence() {
        let store = Self.editing(DaemonStore())
        _ = store.apply(.daemonShutdown)
        #expect(Self.presence(store) == nil)
    }
}
