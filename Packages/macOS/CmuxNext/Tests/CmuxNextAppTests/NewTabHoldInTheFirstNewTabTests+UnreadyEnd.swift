import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextFocusUI
@testable import CmuxNextPages
import CmuxNextTestSupport
import Foundation
import Testing

/// Rows 6, 7 and 8. A letter that the person types in the SECOND new tab, and the key hold of that tab ends with no
/// report of its page: the hold's limit passes (row 6), the person presses Cmd-V (row 7), or the person presses New
/// Tab again (row 8). Row 3 has the same letter with a page that reports.
///
/// The rule: the letter is typed for the second new tab, and it goes there. It is not lost.
///
/// The case of these rows is an app where the second new tab takes the page view of the first new tab, which the
/// person did not touch: the 2 tabs have one page view, and its field was ready before the second New Tab key. The
/// web view of that page had the keyboard at the second New Tab key, so it is what the hold recorded as the view
/// that the person left (`NewTabHoldKeyboard`). It is also the view of the new tab. A hold that ends with no field
/// ready gives no key to the view that the person left, so without a rule for this case the letter is dropped: the
/// hold's log gets a line `dropped 1 keys`.
///
/// Want, in each row: the hold's log has no line of a dropped key, and the page view that the second new tab has got
/// the letter as a key-down. The row reads the host's mark of a key on that view (`AgentPaneHostTouch`), as row 3
/// does for its way 2: the hold's replay sets the mark when it gives a key to an agent page's view, and the view had
/// no mark before the letter.
///
/// Limits. A row stops with a `setup` line in an app where the 2 new tabs have 2 page views: there the view that
/// the person left is another view than the new tab's, and the rows of `LetterBetweenTwoNewTabKeysTests` and
/// `NewTabHoldCloseKeyTests` have that flow. The rows have the WebKit page host only: no row here has a page in a
/// Chromium page window. The row does not read the key event that the web view gets. Row 7 does not send the Cmd-V
/// on, and it does not read the pasteboard.
extension NewTabHoldInTheFirstNewTabTests {
    /// How the key hold of the second new tab ends with no report of its page.
    enum UnreadyEnd: String {
        case limit = "the hold's limit passes"
        case paste = "a Cmd-V"
        case newTab = "a New Tab key"
    }

    static func aLetterInTheSecondNewTabThenAnUnreadyEnd(_ end: UnreadyEnd, row: Int) async throws {
        try await withScene { scene in
            let typed = Typed()
            let two = try await scene.twoNewTabs(typed)
            let page2 = try #require(scene.page(of: two.tab2, into: typed), "setup: the second new tab has no page with a field")
            let shows = scene.pane.currentTabKey == two.tab2 && scene.pane.currentContent?.inputReadiness === page2
            try #require(shows, "setup: the pane does not show the page of the second new tab after one frame of the app")
            let view2 = try #require(scene.services.agentTabs.existingView(two.tab2), "setup: the second new tab has no page view")
            try #require(two.onePage && page2.isReady,
                         """
                         setup: the row needs an app where the second new tab takes the page view of the first one, with a \
                         field that is ready (one page view: \(two.onePage), the field is ready: \(page2.isReady)). With 2 \
                         page views the view that the person left is not the new tab's view, and this row proves nothing.
                         """)
            try #require(!view2.model.hostTouch.marked,
                         "setup: the page view of the second new tab has the host's mark before the letter (by \(view2.model.hostTouch.by ?? "none")): the row then proves nothing")
            try #require(scene.window.firstResponder === view2.webView,
                         "setup: the web view of the second new tab's page does not have the keyboard before the letter (the keyboard: \(scene.keyboard(two)))")
            try #require(!scene.router.creationInputCoordinator.isHolding(in: scene.window),
                         "setup: the window's creation hold is there before the letter and can take it: the row proves nothing")

            let key = try scene.keys.press("b", code: 11, command: false)
            let held = key.took && scene.input.log.last?.hasPrefix("hold key #") == true
            try #require(held, "setup: the key hold of the second new tab did not take the letter. The hold's log ends: \(scene.holdLog)")
            let endsBefore = scene.input.log.filter { $0.hasPrefix("release: ") }.count

            // The hold ends, and no page reported for the second new tab.
            var endKeyTook: Bool?
            switch end {
            case .limit: try scene.passTheLimit()
            case .paste: endKeyTook = try scene.keys.press("v", code: 9, command: true).took
            case .newTab: _ = try scene.newTab()
            }
            // Read before a later frame: after row 8's key the pane shows a third tab.
            let ends = scene.input.log.filter { $0.hasPrefix("release: ") }.dropFirst(endsBefore)
            let dropped = scene.dropped
            let touch = (marked: view2.model.hostTouch.marked, by: view2.model.hostTouch.by)
            let stillTheTabs = scene.services.agentTabs.existingView(two.tab2) === view2
            let hasTheKeyboard = scene.window.firstResponder === view2.webView
            let asAKey = touch.marked && touch.by == "key" && stillTheTabs && (end == .newTab || hasTheKeyboard)
            let keyboard = scene.keyboard(two)
            let endKey = endKeyTook.map { $0 ? "true" : "false" } ?? "no key"
            await LargeSessionWindowFixture.drainMain()
            let got = (first: typed.into(two.tab1), second: typed.into(two.tab2))
            print("""
                NewTabHoldInTheFirstNewTabTests: row \(row), a letter in the second new tab, then \(end.rawValue) with no \
                report of that tab's page: the hold's lines of its end: \(Array(ends)); the hold's lines of dropped keys: \
                \(dropped); the page view of the second tab got the letter as a key-down: \(asAKey) (the host's mark: \
                \(touch.marked), by \(touch.by ?? "none"); the view is still the tab's: \(stillTheTabs); its web view has the \
                keyboard: \(hasTheKeyboard)); the key router took the key of the end: \(endKey); \
                the app made the edits \(got.first) in the first new tab's page and \(got.second) in the second new tab's \
                page; the keyboard after the end: \(keyboard); the test's view got \(scene.old.keys) keys; the hold's log \
                ends: \(scene.holdLog)
                """)
            try #require(!ends.isEmpty, "setup: the key hold of the second new tab did not end at \(end.rawValue). The hold's log ends: \(scene.holdLog)")
            #expect(dropped.isEmpty,
                    """
                    a letter that was typed in the second new tab was lost when its key hold ended with no report of its \
                    page (\(end.rawValue)): \(dropped). The hold's log ends: \(scene.holdLog)
                    """)
            #expect(asAKey,
                    """
                    the page view of the second new tab did not get the letter as a key-down after its key hold ended with \
                    no report of its page (\(end.rawValue)): the host's mark: \(touch.marked), by \(touch.by ?? "none"); the \
                    view is still the tab's: \(stillTheTabs); its web view has the keyboard: \(hasTheKeyboard). The hold's \
                    log ends: \(scene.holdLog)
                    """)
            #expect(got.first.isEmpty && got.second.isEmpty,
                    "the app made the edits \(got.first) and \(got.second) in the pages of the 2 new tabs, want none: the letter is a key-down for a ready field")
            #expect(scene.old.keys == 0, "the view that had the keyboard before the first New Tab key got \(scene.old.keys) keys, want 0")
            if end != .newTab { try await scene.stillReads(page2, into: typed) }
        }
    }

    /// Row 6. The limit of the second tab's key hold passes with the letter in it.
    @Test func aLetterInTheSecondNewTabIsNotDroppedAtTheLimitOfItsHold() async throws {
        try await Self.aLetterInTheSecondNewTabThenAnUnreadyEnd(.limit, row: 6)
    }

    /// Row 7. The person presses Cmd-V after the letter: a key with Command ends the hold, and its keys go on first.
    /// The row proves that the letter BEFORE the Cmd-V is not dropped. It does not send the Cmd-V on, so the arrival
    /// of the paste has no row.
    @Test func aLetterBeforeACmdVInTheSecondNewTabIsNotDropped() async throws {
        try await Self.aLetterInTheSecondNewTabThenAnUnreadyEnd(.paste, row: 7)
    }

    /// Row 8. The person presses New Tab again after the letter: a letter between 2 New Tab keys, with one page view.
    @Test func aLetterInTheSecondNewTabIsNotDroppedAtTheNextNewTabKey() async throws {
        try await Self.aLetterInTheSecondNewTabThenAnUnreadyEnd(.newTab, row: 8)
    }
}
