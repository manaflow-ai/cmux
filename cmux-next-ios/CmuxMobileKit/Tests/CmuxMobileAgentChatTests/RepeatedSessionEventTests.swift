@testable import CmuxMobileAgentChat
import Foundation
import Observation
import Testing

/// The daemon re-sends a session's status, models, modes and commands with every attach and
/// turn event. The chat composer reads them (its placeholder and harness name from `summary`,
/// its menus from the rest), so a repeat that changes nothing must notify no one: each write
/// re-rendered the composer and its text view mid-typing (ask-4a87599079: typing followed the
/// Mac's load).
@MainActor
@Suite struct RepeatedSessionEventTests {
    final class Recorder: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    final class Flag: @unchecked Sendable { var fired = false }

    /// Whether `change` notified a reader of what the composer reads.
    func notifies(_ store: AgentChatStore, _ change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking {
            _ = store.summary
            _ = store.models
            _ = store.currentModelID
            _ = store.modes
            _ = store.currentModeID
            _ = store.availableCommands
            _ = store.configOptions
            _ = store.usage
        } onChange: { flag.fired = true }
        change()
        return flag.fired
    }

    static let models = [ACPModelInfo(id: "opus", name: "Opus")]
    static let modes = [ACPMode(id: "default", name: "Default")]

    func primed() -> AgentChatStore {
        let store = AgentChatStore(source: Recorder())
        store.apply(.status(.idle))
        store.apply(.modelsAvailable(Self.models, current: "opus"))
        store.apply(.modesAvailable(Self.modes, current: "default"))
        store.apply(.update(.usage(used: 10, size: 100)))
        return store
    }

    @Test func aRepeatedStatusNotifiesNoOne() {
        let store = primed()
        #expect(!notifies(store) { store.apply(.status(.idle)) })
        #expect(notifies(store) { store.apply(.status(.disconnected)) })
    }

    @Test func repeatedModelsModesAndUsageNotifyNoOne() {
        let store = primed()
        #expect(!notifies(store) {
            store.apply(.modelsAvailable(Self.models, current: "opus"))
            store.apply(.modesAvailable(Self.modes, current: "default"))
            store.apply(.update(.currentMode("default")))
            store.apply(.update(.usage(used: 10, size: 100)))
        })
        #expect(notifies(store) { store.apply(.update(.usage(used: 11, size: 100))) })
    }
}
