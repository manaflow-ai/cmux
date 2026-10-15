import AppKit
import Foundation
import Testing
@testable import CmuxBrowser

@MainActor
@Suite struct BrowserContextMenuPresenterTests {
    @Test func buildsANativeMenuThatReportsEngineIdsAndRunsHostRows() throws {
        let link = try #require(URL(string: "https://example.com"))
        let submenu = BrowserContextMenuItem(id: 5, title: "Spelling", kind: .submenu, children: [
            BrowserContextMenuItem(id: 6, title: "Check", kind: .check, isChecked: true),
        ])
        let entries: [BrowserContextMenuEntry] = [
            .engine(BrowserContextMenuItem(id: 50100, title: "Open Link in New Tab")),
            .host(.openLinkInDefaultBrowser(link)),
            .separator,
            .engine(BrowserContextMenuItem(id: 9, title: "Disabled", isEnabled: false)),
            .engine(submenu),
            .separator,
            .host(.toggleFocusMode(isActive: true)),
        ]
        var chosen: [Int] = []
        var hosted: [BrowserContextMenuHostAction] = []
        let menu = BrowserContextMenuPresenter().makeMenu(entries, performHostAction: { hosted.append($0) }, chooseEngineItem: { chosen.append($0) })

        #expect(menu.items.map(\.title) == [
            "Open Link in New Tab", BrowserContextMenuPresenter.title(for: .openLinkInDefaultBrowser(link)), "",
            "Disabled", "Spelling", "", BrowserContextMenuPresenter.title(for: .toggleFocusMode(isActive: true)),
        ])
        #expect(menu.items[2].isSeparatorItem && menu.items[5].isSeparatorItem)
        #expect(!menu.items[3].isEnabled)
        #expect(menu.items[6].state == .on)
        let check = try #require(menu.items[4].submenu?.items.first)
        #expect(check.state == .on)

        BrowserMenuActionTarget.target(of: menu.items[0])?.run(nil)
        BrowserMenuActionTarget.target(of: check)?.run(nil)
        BrowserMenuActionTarget.target(of: menu.items[1])?.run(nil)
        #expect(chosen == [50100, 6])
        #expect(hosted == [.openLinkInDefaultBrowser(link)])
    }

    @Test func aViewOutsideAWindowCompletesWithoutAMenu() {
        var answers: [Int?] = []
        BrowserContextMenuPresenter().present(
            [.engine(BrowserContextMenuItem(id: 1, title: "A"))], at: .zero, in: NSView(),
            performHostAction: { _ in }, completion: { answers.append($0) }
        )
        #expect(answers == [nil])
    }

    @Test func completionAnswersOnce() {
        var answers: [Int?] = []
        let once = BrowserContextMenuCompletion { answers.append($0) }
        once.finish(3)
        once.finish(nil)
        #expect(answers == [3])
    }
}
