import AppKit
@testable import CmuxNextBrowser
import Testing

/// `<select>` popups drawn by cmux: POPUP_MENU's data becomes a cmux menu over the
/// page view, the choice or the dismissal is the one answer, and POPUP_MENU_HIDE, the page's close and
/// the host's end close it with none.
@MainActor
@Suite struct ChromiumHostPopupMenusTests {
    @MainActor
    final class RecordingWire: ChromiumHostPopupMenuWire {
        var replies: [(browser: Int32, token: Int64, index: Int32)] = []
        func reply(browser: Int32, token: Int64, index: Int32) { replies.append((browser, token, index)) }
    }

    /// The deferred turns and the tracked menus, run when the test says.
    @MainActor
    final class Loop {
        var pending: [@MainActor () -> Void] = []
        var tracked: [ChromiumHostPopupMenuRun] = []
        /// What the next tracking returns (the chosen row), and what it does while it tracks.
        var choose: Int?
        var whileTracking: (@MainActor () -> Void)?

        func turn() {
            let work = pending
            pending = []
            for body in work { body() }
        }
    }

    /// Keeps the test's windows (a view holds its window weakly); none is ever ordered in.
    @MainActor
    final class Windows {
        var all: [NSWindow] = []
    }

    let browser: Int32 = 7
    let windows = Windows()

    /// A page view in a window, 800 by 600 points.
    func pageView() -> NSView {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.isReleasedWhenClosed = false
        windows.all.append(window)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = view
        return view
    }

    func makeMenus(_ wire: RecordingWire, _ loop: Loop, view: NSView?) -> ChromiumHostPopupMenus {
        var seams = ChromiumHostPopupMenus.Seams()
        seams.later = { loop.pending.append($0) }
        seams.track = { run in
            loop.tracked.append(run)
            loop.whileTracking?()
            return loop.choose
        }
        return ChromiumHostPopupMenus(wire: wire, pageView: { [browser] id in id == browser ? view : nil }, seams: seams)
    }

    func popup(selected: Int = 1) -> ChromiumHostPopupMenu {
        ChromiumHostPopupMenu(bounds: CGRect(x: 40, y: 220, width: 240, height: 32),
                              items: [.init(label: "Fruit", kind: .group), .init(label: "  Apple "), .init(label: "", kind: .separator),
                                      .init(label: "Banana", enabled: false), .init(label: "Cherry", kind: .checkable, checked: true)],
                              selected: selected, fontSize: 13.5)
    }

    // MARK: The event's data

    /// The shim's JSON (CEFShim/src/popup_menu_args.h; the same string popup_menu_args_test.cpp checks)
    /// decodes every field; an item kind this cmux does not know is a label nobody can choose.
    @Test func theShimsJSONDecodes() throws {
        let json = #"{"x":40,"y":-12,"width":240,"height":32,"fontSize":13.500,"selected":1,"rightAligned":true,"items":["#
            + #"{"label":"Fruit","toolTip":"","type":2,"enabled":true,"checked":false,"rtl":false,"directionOverride":false},"#
            + #"{"label":"Apple","toolTip":"a \"red\" one\\","type":0,"enabled":true,"checked":false,"rtl":false,"directionOverride":false},"#
            + #"{"label":"\#u{5E9}\#u{5DC}\#u{5D5}\#u{5DD}","toolTip":"tab\u0009here","type":1,"enabled":false,"checked":true,"rtl":true,"directionOverride":true},"#
            + #"{"label":"later","toolTip":"","type":9,"enabled":true,"checked":false,"rtl":false,"directionOverride":false}]}"#
        let popup = try #require(ChromiumHostPopupMenu(json: json))
        #expect(popup.bounds == CGRect(x: 40, y: -12, width: 240, height: 32))
        #expect(popup.fontSize == 13.5 && popup.selected == 1 && popup.rightAligned)
        #expect(popup.items.map(\.label) == ["Fruit", "Apple", "\u{5E9}\u{5DC}\u{5D5}\u{5DD}", "later"])
        #expect(popup.items[1].toolTip == #"a "red" one\"#)
        #expect(popup.items.map(\.kind) == [.group, .option, .checkable, .group])
        #expect(popup.items.map(\.isChoosable) == [false, true, false, false])
        #expect(popup.items[2].rtl && popup.items[2].directionOverride && popup.items[2].checked)
        #expect(ChromiumHostPopupMenu(json: "{") == nil)
        #expect(ChromiumHostPopupMenu(json: #"{"x":1}"#) == nil)
    }

    @Test func theEventDecodes() {
        let json = #"{"x":1,"y":2,"width":3,"height":4,"fontSize":0.000,"selected":-1,"rightAligned":false,"items":[]}"#
        let shown = CEFShimEvent(kind: 58, browser: 7, request: 0, a: 9_007_199_254_740_993, b: 0, s1: json, s2: "")
        #expect(shown == .popupMenu(browser: 7, token: 9_007_199_254_740_993,
                                    popup: ChromiumHostPopupMenu(bounds: CGRect(x: 1, y: 2, width: 3, height: 4), items: [])))
        #expect(shown.browserID == 7)
        #expect(CEFShimEvent(kind: 58, browser: 7, request: 0, a: 5, b: 0, s1: "not json", s2: "") ==
            .popupMenu(browser: 7, token: 5, popup: nil))
        #expect(CEFShimEvent(kind: 59, browser: 7, request: 0, a: 5, b: 0, s1: "", s2: "") == .popupMenuHidden(browser: 7, token: 5))
    }

    // MARK: One answer per popup

    /// The menu shows on the next turn, never inside the event, and the chosen row is the answer.
    @Test func theChosenRowIsTheAnswer() {
        let wire = RecordingWire(), loop = Loop()
        let menus = makeMenus(wire, loop, view: pageView())
        loop.choose = 4
        menus.show(browser: browser, token: 41, popup: popup())
        #expect(loop.tracked.isEmpty && wire.replies.isEmpty)
        loop.turn()
        #expect(loop.tracked.count == 1)
        #expect(wire.replies.map(\.index) == [4] && wire.replies.map(\.token) == [41] && wire.replies.map(\.browser) == [browser])
        #expect(menus.presentedMenu == nil)
    }

    /// A dismissed menu, or a row the page cannot take (a group label, a separator, a disabled option,
    /// an index past the items), answers -1, so the page's popup closes.
    @Test func noChoiceAnswersMinusOne() {
        for choice in [nil, 0, 2, 3, 99] as [Int?] {
            let wire = RecordingWire(), loop = Loop()
            let menus = makeMenus(wire, loop, view: pageView())
            loop.choose = choice
            menus.show(browser: browser, token: 1, popup: popup())
            loop.turn()
            #expect(wire.replies.map(\.index) == [-1], "choice \(String(describing: choice))")
        }
    }

    /// Chromium took the popup back (PopupMenuRunner.Hide) before the menu showed, or while it tracked:
    /// no answer, and a later turn shows nothing.
    @Test func hideClosesWithNoAnswer() {
        let wire = RecordingWire(), loop = Loop()
        let menus = makeMenus(wire, loop, view: pageView())
        menus.show(browser: browser, token: 1, popup: popup())
        menus.hide(browser: browser, token: 1)
        loop.turn()
        #expect(loop.tracked.isEmpty && wire.replies.isEmpty)

        loop.choose = 1
        loop.whileTracking = { menus.hide(browser: self.browser, token: 2) }
        menus.show(browser: browser, token: 2, popup: popup())
        loop.turn()
        #expect(loop.tracked.count == 1 && wire.replies.isEmpty)
        #expect(menus.presentedMenu == nil)

        // Another token, or another page's, hides nothing.
        loop.whileTracking = {
            menus.hide(browser: self.browser, token: 99)
            menus.hide(browser: 8, token: 3)
        }
        menus.show(browser: browser, token: 3, popup: popup())
        loop.turn()
        #expect(wire.replies.map(\.index) == [1])
    }

    /// The page closed, or the host ended: the menu goes with no answer, there is no one to answer.
    @Test func thePagesCloseAndTheHostsEndCloseIt() {
        let wire = RecordingWire(), loop = Loop()
        let menus = makeMenus(wire, loop, view: pageView())
        menus.show(browser: browser, token: 1, popup: popup())
        menus.ownerClosed(8)
        menus.ownerClosed(browser)
        loop.turn()
        loop.whileTracking = { menus.hostEnded() }
        menus.show(browser: browser, token: 2, popup: popup())
        loop.turn()
        #expect(loop.tracked.count == 1 && wire.replies.isEmpty)
    }

    /// The page has one popup: a new one ends the one before it, which answers -1 at once.
    @Test func aNewPopupEndsTheOneBefore() {
        let wire = RecordingWire(), loop = Loop()
        let menus = makeMenus(wire, loop, view: pageView())
        menus.show(browser: browser, token: 1, popup: popup())
        menus.show(browser: browser, token: 2, popup: popup())
        #expect(wire.replies.map(\.token) == [1] && wire.replies.map(\.index) == [-1])
        loop.choose = 1
        loop.turn()
        #expect(loop.tracked.count == 1)
        #expect(wire.replies.map(\.token) == [1, 2] && wire.replies.map(\.index) == [-1, 1])
    }

    /// A popup that came while another tracked ends it; the first menu's run sends nothing more.
    @Test func aPopupDuringTrackingEndsTheTrackedOne() {
        let wire = RecordingWire(), loop = Loop()
        let menus = makeMenus(wire, loop, view: pageView())
        loop.choose = 1
        loop.whileTracking = {
            loop.whileTracking = nil
            menus.show(browser: self.browser, token: 2, popup: self.popup())
        }
        menus.show(browser: browser, token: 1, popup: popup())
        loop.turn()
        #expect(wire.replies.map(\.token) == [1] && wire.replies.map(\.index) == [-1])
        loop.turn()
        #expect(wire.replies.map(\.token) == [1, 2] && wire.replies.map(\.index) == [-1, 1])
    }

    /// A popup cmux cannot show (unreadable JSON, a page no pane shows, a pane in no window, a page that
    /// left its pane before the turn) is answered -1, so the page never waits on a menu that is not there.
    @Test func aPopupWithNoPlaceToShowAnswersMinusOne() {
        let wire = RecordingWire(), loop = Loop()
        let menus = makeMenus(wire, loop, view: pageView())
        menus.show(browser: browser, token: 1, popup: nil)
        menus.show(browser: 8, token: 2, popup: popup())
        let unplaced = makeMenus(wire, loop, view: NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)))
        unplaced.show(browser: browser, token: 3, popup: popup())
        #expect(wire.replies.map(\.token) == [1, 2, 3] && wire.replies.allSatisfy { $0.index == -1 })

        var shown: NSView? = pageView()
        let leaving = ChromiumHostPopupMenus(wire: wire, pageView: { _ in shown }, seams: {
            var seams = ChromiumHostPopupMenus.Seams()
            seams.later = { loop.pending.append($0) }
            seams.track = { _ in Issue.record("a page that left its pane shows no menu"); return 1 }
            return seams
        }())
        leaving.show(browser: browser, token: 4, popup: popup())
        shown = nil
        loop.turn()
        #expect(wire.replies.map(\.token) == [1, 2, 3, 4] && wire.replies.allSatisfy { $0.index == -1 })
    }

    // MARK: The menu

    /// Rows keep the items' order and index (separators too), as Chrome's WebMenuRunner builds them:
    /// only options the page can take are enabled, the page's font size and the title type-select
    /// matches without the label's outer spaces.
    @Test func theMenuHasTheItems() {
        let view = pageView()
        let run = ChromiumHostPopupMenuRun(popup(), in: view)
        let rows = run.menu.items
        #expect(rows.count == 5)
        #expect(rows.map(\.tag) == [0, 1, 2, 3, 4])
        #expect(rows[2].isSeparatorItem)
        #expect([rows[0], rows[1], rows[3], rows[4]].map(\.isEnabled) == [false, true, false, true])
        #expect(rows[1].title == "Apple" && rows[1].attributedTitle?.string == "  Apple ")
        let font = rows[1].attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 13.5)
        #expect(!run.menu.autoenablesItems)
        // The menu goes over the <select>: page view points from the top left, in an unflipped view.
        #expect(run.rect == CGRect(x: 40, y: 600 - 220 - 32, width: 240, height: 32))
        #expect(run.selected == 1)
        // A row's action records its index, which the tracking returns.
        #expect(rows[4].target === run.choice && rows[4].action == #selector(ChromiumHostPopupMenuRun.Choice.chose(_:)))
        #expect(run.choice.index == nil)
        run.choice.chose(rows[4])
        #expect(run.choice.index == 4)
    }

    /// A right-to-left `<select>` aligns its rows right; an item's own direction and override reach its title.
    @Test func directionReachesTheRows() {
        var rtl = popup()
        rtl.rightAligned = true
        rtl.items[1].rtl = true
        rtl.items[1].directionOverride = true
        let run = ChromiumHostPopupMenuRun(rtl, in: pageView())
        let title = run.menu.items[1].attributedTitle
        let paragraph = title?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(paragraph?.alignment == .right && paragraph?.baseWritingDirection == .rightToLeft)
        let override = title?.attribute(.writingDirection, at: 0, effectiveRange: nil) as? [NSNumber]
        #expect(override == [NSNumber(value: NSWritingDirection.rightToLeft.rawValue | NSWritingDirectionFormatType.override.rawValue)])
        #expect(run.rightAligned)
    }
}
