#if os(iOS)
import CmuxMobileModel
import CmuxMobileTerminal
import CmuxMobileWorkspaces
import SwiftUI
import Testing
@testable import CmuxMobileShell

@MainActor @Suite struct TerminalRetryTests {
    @Test func pendingTerminalRetriesTheOwningMacAndRechecksItsSource() async throws {
        let source = GhosttyTerminalTabContent()
        source.frameStore = nil
        let store = AppStore.mock()
        let workspace = try #require(store.workspaces.first { $0.tabs.contains { $0.kind == .terminal } })
        let tab = try #require(workspace.tabs.first { $0.kind == .terminal })
        var requested: [String] = []
        var sourceChecks = 0
        source.reconnect = { requested.append($0) }
        source.sessionProvider = { _, _ in nil }
        source.hasLiveSession = { _, _ in sourceChecks += 1; return false }
        _ = source.page(for: tab, in: workspace,
                        context: TerminalTabContext(safeAreaInsets: .init(), isInteractive: true,
                                                    isZoomGestureActive: false, reportScroll: { _ in }))
        let model = try #require(source.model(forTabID: tab.id))
        let retry = try #require(model.reconnect)
        let before = sourceChecks
        await retry()
        #expect(requested == [workspace.macID])
        #expect(sourceChecks > before)
        #expect(!model.connectionState.isAttached)
        source.reset()
    }
}
#endif
