#if os(iOS)
import CmuxMobileModel
import CmuxMobileTerminal
import CmuxMobileWorkspaces
import SwiftUI
import Testing
@testable import CmuxMobileShell

/// Grid cards use the cached frame or a short screen read. They must not open a
/// daemon terminal attach for every card before the person opens a tab.
@MainActor @Suite struct TerminalCardSessionTests {
    @Test func preparingACardDoesNotCreateALiveTerminalSession() throws {
        let source = GhosttyTerminalTabContent()
        source.frameStore = nil
        let store = AppStore.mock()
        let workspace = try #require(store.workspaces.first { $0.tabs.contains { $0.kind == .terminal } })
        let tab = try #require(workspace.tabs.first { $0.kind == .terminal })
        var requests = 0
        var availableSession: (any TerminalSession)?
        source.sessionProvider = { _, _ in
            requests += 1
            return availableSession
        }

        _ = source.card(for: tab, in: workspace)
        source.prepareCard(for: tab, in: workspace)
        #expect(requests == 0)

        source.workspaceLookup = { _ in workspace }
        source.hasLiveSession = { _, _ in true }
        source.liveDataChanged()
        #expect(requests == 0)

        _ = source.page(for: tab, in: workspace,
                        context: TerminalTabContext(safeAreaInsets: .init(), isInteractive: true,
                                                    isZoomGestureActive: false, reportScroll: { _ in }))
        #expect(requests == 1)

        availableSession = PendingTerminalSession(macName: "Mac", programName: "zsh")
        source.liveDataChanged()
        #expect(requests == 2)
        source.reset()
    }
}
#endif
