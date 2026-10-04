import AppKit
import CmuxNextActions
import CmuxNextHistory
import Foundation
import Testing
@testable import CmuxNextApp

/// R69 (Lawrence 2026-10-04): Back and Forward follow the static sidebar
/// toggle in the titlebar band. A click runs focusHistoryBack /
/// focusHistoryForward (the shortcut's actions); a right-click or long
/// press lists the in-scope entries and choosing one runs history.goTo.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct TitlebarHistoryButtonsTests {
    @Test func backAndForwardFollowTheToggleAndRunTheHistoryActions() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        for _ in 0..<10 { await Task.yield() }
        harness.window.window?.contentView?.layoutSubtreeIfNeeded()
        let root = harness.window.root
        let toggle = try #require(root.sidebarToggleFrame)
        let back = try #require(root.historyButtonFrame(.back))
        let forward = try #require(root.historyButtonFrame(.forward))
        #expect(back.minX >= toggle.maxX && forward.minX >= back.maxX && back.midY == toggle.midY)
        var ran: [ActionID] = []
        harness.services.registry.bind("focusHistoryBack", run: { _ in ran.append("focusHistoryBack") })
        harness.services.registry.bind("focusHistoryForward", run: { _ in ran.append("focusHistoryForward") })
        root.pressHistoryButton(.back)
        root.pressHistoryButton(.forward)
        #expect(ran == ["focusHistoryBack", "focusHistoryForward"])
    }

    @Test func theListShowsEachEntryAndChoosingRunsGoTo() {
        func entry(_ title: String, workspace: String?) -> LocationTrail.Entry {
            LocationTrail.Entry(location: HistoryLocation(key: .init(machine: "local", tab: title), window: "w", workspace: "ws", pane: "p",
                                                          content: .terminal, title: title, workspaceTitle: workspace),
                                enteredAt: Date(timeIntervalSince1970: 0))
        }
        let items = [LocationTrailListItem(index: 3, entry: entry("vim", workspace: "cmux")),
                     LocationTrailListItem(index: 1, entry: entry("zsh", workspace: nil))]
        var chosen: [Int] = []
        let menu = TitlebarHistoryMenu.make(items) { chosen.append($0) }
        #expect(menu.items.map(\.title) == ["vim — cmux", "zsh"])
        menu.items.forEach { $0.target.flatMap { target in _ = (target as AnyObject).perform($0.action, with: $0) } }
        #expect(chosen == [3, 1])
    }
}
