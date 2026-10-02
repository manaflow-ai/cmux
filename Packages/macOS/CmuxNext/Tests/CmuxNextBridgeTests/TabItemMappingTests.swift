import CmuxNextDaemon
import CmuxNextTabs
import Testing
@testable import CmuxNextBridge

/// A tab shows its terminal's progress as the daemon parses it for every
/// terminal, not only the mounted ones: running progress spins the icon,
/// an error marks the tab failed.
@MainActor
struct TabItemMappingTests {
    @Test func terminalProgressFromTheDaemonDrivesTheTab() throws {
        let store = try BridgeFixture.store()
        let tab = try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first)
        let terminal = try #require(tab.terminalResourceID)
        #expect(!TabItemMapping.shared.item(tab, fallbackTitle: "t").isBusy)

        var state = SessionStateMirror()
        state.terminalProgress[terminal] = TerminalProgressReport(state: .normal, value: 40)
        store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .sessionState(.snapshot(state)))])
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").isBusy)

        state.terminalProgress[terminal] = TerminalProgressReport(state: .error, value: 40)
        store.apply(batch: [DaemonEventEnvelope(sequence: 2, event: .sessionState(.snapshot(state)))])
        let failed = TabItemMapping.shared.item(tab, fallbackTitle: "t")
        #expect(!failed.isBusy && failed.status == .failure)

        state.terminalProgress[terminal] = nil
        store.apply(batch: [DaemonEventEnvelope(sequence: 3, event: .sessionState(.snapshot(state)))])
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").status == .none)
    }
}
