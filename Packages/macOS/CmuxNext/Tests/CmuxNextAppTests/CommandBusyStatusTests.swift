import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Observation
import Testing

/// A plain shell command shows as running on its workspace row (cx-urd.65). The daemon publishes the
/// running command on the terminal record (`extra.busy`, OSC 133 C..D, terminal-activity-v1); the row
/// shows it busy once it has run `status.inferCommandBusyAfter`, and idle again at the prompt.
@MainActor @Suite(.serialized)
struct CommandBusyStatusTests {
    /// A store with one terminal tab whose session stream carries `extra` for its terminal.
    func store(extra: String) throws -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"terminals":[{"id":"term_7","extra":\#(extra)}],"extra":{"state":{}}}}}"#
        let item = try #require(SessionStreamItem.decode(Data(line.utf8)))
        store.session.apply(item, to: store.workspaces)
        return store
    }

    /// `extra` of a terminal whose command started `ago` seconds before now.
    func running(since ago: Double) -> String {
        let since = UInt64((Date().timeIntervalSince1970 - ago) * 1000)
        return #"{"busy":{"since_ms":"\#(since)"}}"#
    }

    func activity(_ store: DaemonStore) throws -> StatusIndicatorState {
        SidebarMapping.shared.row(try #require(store.workspaces.first), machine: .local).activity
    }

    @Test func aCommandRunningPastTheThresholdShowsRunningOnItsRow() throws {
        #expect(try activity(store(extra: running(since: 10))) == .busy(progress: nil))
    }

    @Test func aCommandShowsOnceItHasRunTheThresholdAndTheRowRedraws() async throws {
        let saved = DesignSettings.shared.statusBehavior
        defer { DesignSettings.shared.statusBehavior = saved }
        DesignSettings.shared.statusBehavior.inferCommandBusyAfter = 0.3
        let store = try store(extra: running(since: 0))
        let changed = Flag()
        let before = withObservationTracking { (try? activity(store)) ?? .idle } onChange: { changed.set() }
        #expect(before == .idle)
        for _ in 0..<60 where !changed.isSet { try await Task.sleep(for: .milliseconds(50)) }
        #expect(changed.isSet, "the row was not told to redraw when the command came of age")
        #expect(try activity(store) == .busy(progress: nil))
    }

    /// An agent CLI is one long shell command: idle at its own prompt, its row shows the agent's
    /// state, never the command running.
    @Test func anIdleAgentsTerminalDoesNotShowItsCommandRunning() throws {
        let store = try store(extra: running(since: 10))
        let tab = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        tab.setAgent(AgentStatus(surface: 1, state: .idle, source: "hook", agent: "claude"))
        #expect(try activity(store) == .idle)
    }

    @Test func aPromptOrTheSettingOffShowsIdle() throws {
        #expect(try activity(store(extra: "{}")) == .idle)
        let saved = DesignSettings.shared.statusBehavior
        defer { DesignSettings.shared.statusBehavior = saved }
        DesignSettings.shared.statusBehavior.inferCommandBusy = false
        #expect(try activity(store(extra: running(since: 10))) == .idle)
    }
}

/// Set once from an observation's `onChange` (any thread).
private nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
