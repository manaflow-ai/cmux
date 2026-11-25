import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Row 14. A hold of New Tab keys, and then the Close Tab key: the person's own order. The page view of the hold is
/// in the tab of the last key. A Close Tab key closes that tab, and the pane shows the tab beside it, which has no
/// page view of its own. Want, in the turn of the Close Tab key (no frame between the key and the read): the strip
/// lost the closed tab and no other; no page view was made; the pane shows the tab that the strip selects now; that
/// tab has the page view that the pane showed before the key; that page view is in the pane's window and not hidden;
/// and the keyboard is in it. Then a second Close Tab key in the same turn, with the same read, and the same read one
/// frame later.
///
/// The row has 2 forms, by the state of the creation of the tab that the first Close Tab key closes:
/// - answered: the daemon made the tab of each key before the Close Tab key. The close asks the daemon.
/// - not answered: the request for the 6th tab waits in the row and does not go to the daemon, so the tab is a
///   stand-in when the Close Tab key comes, one frame after its New Tab key. The close cancels the creation. This is
///   a Close Tab key that comes before a slow answer.
///
/// The 6th New Tab key and each Close Tab key are key-down events with Command: first to the page's view
/// (`AgentPaneView.judge`, which the app's event monitor calls), then through the key router
/// (`KeyRouter.interceptKeyDown`), as in row 6. The row requires that the Close Tab action is on Cmd-W.
///
/// Limits. No HID event and no event monitor: the keys start at the page's view and the key router. The keyboard is
/// read as the window's first responder: the row does not read the caret of a field of the page. When the app did not
/// give the page the keyboard before the Close Tab keys, the row gives it, and its print says which of the 2 it was.
extension NewTabHoldMovesItsPageTests {
    /// The state of the creation of the tab that the first Close Tab key closes.
    enum Creation: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case answered = "answered"
        case notAnswered = "not answered"

        var testDescription: String { rawValue }
    }

    /// What the row reads in the turn of one Close Tab key, or one frame later (then only what the pane shows).
    struct CloseRead {
        var took = false, wasPending = false, tookTheTab = false, made = 0
        var showsANewTab = false, showsTheSelection = false, hasThePage = false, pageIsShown = false, keyboard = false
        /// The page view has the host's mark of an input of the person (a page with it never goes to another tab).
        var touched = false

        /// What the pane shows that is not as the row wants it, in words.
        var showFaults: [String] {
            var all: [String] = []
            if !showsANewTab { all.append("the pane shows no New Tab tab") }
            if !showsTheSelection { all.append("the pane does not show the tab that the strip selects") }
            if !hasThePage { all.append("the shown tab does not have the page view that the pane showed before the keys") }
            if !pageIsShown { all.append("that page view is hidden or in no window of the pane") }
            if !keyboard { all.append("the keyboard is not in that page view") }
            return all
        }

        /// The same with what the key itself did.
        var faults: [String] {
            var all: [String] = []
            if !took { all.append("the key router passed the key on") }
            if !tookTheTab { all.append("the strip did not lose the tab that it selected at the key, and only that tab") }
            if made != 0 { all.append("\(made) page views made") }
            return all + showFaults
        }

        static func words(_ faults: [String]) -> String { faults.isEmpty ? "each fact as wanted" : faults.joined(separator: "; ") }
    }

    /// What the pane shows now, against the page view `page`. It has no suspension point.
    static func shows(_ page: AgentPaneView, in pane: PaneController, _ services: AppServices, window: NSWindow) -> CloseRead {
        let tabs = services.agentTabs, shown = pane.currentTabKey
        var read = CloseRead()
        read.showsANewTab = shown.map { tabs.isNewTabPage($0) } ?? false
        read.showsTheSelection = shown != nil && shown == pane.stripModel.selectedID?.rawValue
        read.hasThePage = shown.flatMap { tabs.existingView($0) } === page
        read.pageIsShown = page.window != nil && page.window === pane.view.window && !page.isHiddenOrHasHiddenAncestor
        read.keyboard = (window.firstResponder as? NSView)?.isDescendant(of: page.webView) == true
        read.touched = page.model.hostTouch.marked
        return read
    }

    /// One Close Tab key and the read in its turn. It has no suspension point: no other task of the main actor (a
    /// frame of the app, an answer of the daemon) runs between the key and the read.
    static func closeTabKey(_ page: AgentPaneView, in pane: PaneController, _ services: AppServices, _ views: Views,
                            window: NSWindow) throws -> CloseRead {
        let router = services.keyRouter
        let closing = try #require(pane.stripModel.selectedID, "setup: the strip selects no tab before the Close Tab key")
        let wasPending = pane.daemon.store.creations.isPending(tab: closing.rawValue)
        let strip = pane.orderedIDs.count, made = views.count
        let event = try keyDown("w", code: 13, command: true, in: window)
        let action = services.registry.resolveShortcut(for: event)?.id
        try #require(action == "closeTab", "setup: Cmd-W is not the Close Tab action here (\(action?.rawValue ?? "no action"))")
        page.judge(event, eventWindow: window)
        let took = router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) }
        var read = shows(page, in: pane, services, window: window)
        _ = views.read(pane, services)
        read.took = took
        read.wasPending = wasPending
        read.tookTheTab = !pane.orderedIDs.contains(closing) && pane.orderedIDs.count == strip - 1
        read.made = views.count - made
        return read
    }

    @Test(arguments: Creation.allCases) func aCloseTabKeyAfterAHoldShowsTheNextTabWithTheHoldsPageView(creation: Creation) async throws {
        try await Self.row("cn-hold-moves-page-close-key-\(creation == .answered ? "answered" : "held")") { services, pane, views, _ in
            let tabs = services.agentTabs, router = services.keyRouter, creations = pane.daemon.store.creations
            let held = await Self.hold(5, in: pane, services, views)
            try #require(held.pressed == 5 && held.made == 0,
                         "setup: the hold of 5 New Tab keys pressed \(held.pressed) keys and made \(held.made) page views, want 5 and 0")
            let page = try #require(pane.currentTabKey.flatMap { tabs.existingView($0) }, "setup: the tab of the 5th key has no page view")
            let window = try #require(pane.view.window, "setup: the pane's view is in no window")
            // Not answered: the request for each tab from here on waits in the row and never goes to the daemon (the
            // form of `NewTabHoldInTheFirstNewTabTests`): at the row's end it ends as a creation that was cancelled.
            let gate = NewTabHoldInTheFirstNewTabTests.HeldCreations(), create = tabs.create
            if creation == .notAnswered {
                tabs.create = { _, _, _, _, _, _ in
                    await gate.wait()
                    throw CancellationError()
                }
            }
            defer {
                tabs.create = create
                gate.release()
            }
            // The 6th New Tab key, as the app gets a key, with the keyboard in the page.
            if (window.firstResponder as? NSView)?.isDescendant(of: page.webView) != true { _ = try Self.keyboard(to: page, in: pane) }
            let strip = pane.orderedIDs.count
            let sixth = try Self.keyDown("t", code: 17, command: true, in: window)
            page.judge(sixth, eventWindow: window)
            let tookTheSixth = router.dispatchingSynthetic(sixth) { router.interceptKeyDown(sixth, in: window) }
            try #require(tookTheSixth, "setup: the key router passed the 6th New Tab key on")
            try #require(pane.orderedIDs.count == strip + 1, "setup: the 6th New Tab key added \(pane.orderedIDs.count - strip) tabs to the strip, want 1")
            await NewTabPageAtItsFrameTests.frame(services)
            switch creation {
            case .answered:
                try await PasswordManagerRouteTests.until({ pane.orderedIDs.allSatisfy { !creations.isPending(tab: $0.rawValue) } },
                                                          within: .seconds(10), report: { "setup: the daemon did not answer each creation of the 6 keys" })
            case .notAnswered:
                let selected = try #require(pane.stripModel.selectedID?.rawValue, "setup: the strip selects no tab after the 6th key")
                try #require(creations.isPending(tab: selected), "setup: the store does not have the 6th tab as a creation that waits, one frame after its key")
            }
            let sixthTab = try #require(pane.currentTabKey, "setup: the pane shows no tab before the Close Tab key")
            try #require(tabs.isNewTabPage(sixthTab) && sixthTab == pane.stripModel.selectedID?.rawValue,
                         "setup: the pane does not show the New Tab tab that the strip selects before the Close Tab key")
            try #require(tabs.existingView(sixthTab) === page, "setup: the 6th tab does not have the page view of the hold before the Close Tab key")
            // The keyboard is in the page before the Close Tab key: by the app, else by the row.
            let byTheApp = (window.firstResponder as? NSView)?.isDescendant(of: page.webView) == true
            if !byTheApp { _ = try Self.keyboard(to: page, in: pane) }

            // The 2 Close Tab keys and their reads: one turn of the main actor.
            let first = try Self.closeTabKey(page, in: pane, services, views, window: window)
            let second = try Self.closeTabKey(page, in: pane, services, views, window: window)
            await NewTabPageAtItsFrameTests.frame(services)
            let later = Self.shows(page, in: pane, services, window: window)
            _ = views.read(pane, services)
            print("""
                NewTabHoldMovesItsPageTests: row 14, 2 Close Tab keys after a hold of 6 New Tab keys, the 6th tab's creation \
                \(creation.rawValue): the page had the keyboard before the Close Tab keys by \(byTheApp ? "the app" : "the row"); \
                key 1 (its tab was a creation that waits: \(first.wasPending); the page has the host's mark after it: \
                \(first.touched)): \(CloseRead.words(first.faults)); key 2 (its tab was a creation that waits: \
                \(second.wasPending); the mark: \(second.touched)): \(CloseRead.words(second.faults)); one frame later: \
                \(CloseRead.words(later.showFaults))
                """)
            #expect(first.wasPending == (creation == .notAnswered),
                    "setup: the tab of the first Close Tab key was a creation that waits: \(first.wasPending), the row's form is `\(creation.rawValue)`")
            #expect(first.faults.isEmpty, "in the turn of the first Close Tab key (the 6th tab, its creation \(creation.rawValue)): \(first.faults)")
            #expect(second.faults.isEmpty, "in the turn of the second Close Tab key: \(second.faults)")
            #expect(later.showFaults.isEmpty, "one frame after the 2 Close Tab keys: \(later.showFaults)")
        }
    }
}
