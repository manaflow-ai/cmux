import AppKit
import CmuxNextDesignTokens
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextPages

/// Which agent pane view shows its page in a Chromium page window (`AgentPaneView.chromiumAgentPane(under:in:)`).
/// Chromium draws a page in a child window, and the app finds the view of such a window by its place. A pane has
/// more than one agent page view at one place: it keeps the views that it does not show as hidden views, and for the
/// time of a paint hold it shows the old view while the new view is above it and not hidden, at alpha 0. The app
/// tells Chromium which page of the place shows, and only a page that shows has the keys in its window. Want: the
/// lookup answers the view of the page that the app told Chromium to show, and no view when it told none.
///
/// Each page is a fake Chromium page that records what the app told it. The page window is a plain child window at
/// the place of the views: the fake makes no window. The rows read the lookup's answer, not which window is key.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPaneUnderAPageWindowTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The incoming side of a paint hold. The hold takes a view that says when it painted, and the agent pane view
    /// says that in the app target only: here the view is in this one, as a page view is in a window's top page.
    private final class Incoming: NSView, PaneFirstPaintGated {
        var awaitsFirstPaint: Bool { true }
        func whenFirstPainted(_ body: @escaping () -> Void) {}
    }

    /// A model of a pane's host in a layout: it says whether its pane left the layout, as the layout's host view does.
    private final class PaneHost: NSView, PaneLeaving {
        var isLeaving = false
    }

    /// 2 agent pane views with a page in Chromium, a window, and a child window over the window's content.
    @MainActor
    private struct Place {
        let first: AgentPaneView, second: AgentPaneView
        let firstPage: FakeChromiumPage, secondPage: FakeChromiumPage
        let window: NSWindow, host: NSView, pageWindow: NSWindow

        func close() {
            first.page?.close()
            second.page?.close()
            window.removeChildWindow(pageWindow)
            pageWindow.close()
            window.close()
        }

        /// The lookup's answer for the page window, in words.
        func answer() -> String {
            guard let pane = AgentPaneView.chromiumAgentPane(under: pageWindow, in: window) else { return "no view" }
            if pane === first { return "the first view" }
            return pane === second ? "the second view" : "another view"
        }

        /// What the app told Chromium last: whether each page shows.
        var told: String {
            "the first page visible \(String(describing: firstPage.visibility.last)), the second page visible \(String(describing: secondPage.visibility.last))"
        }

        /// Whether the Chromium content view of `pane` is in the window and under the page window's centre.
        func isUnderThePageWindow(_ pane: AgentPaneView) -> Bool {
            guard let content = pane.chromiumPage?.contentView, let host = content.window else { return false }
            let center = CGPoint(x: pageWindow.frame.midX, y: pageWindow.frame.midY)
            return host.convertToScreen(content.convert(content.bounds, to: nil)).contains(center)
        }
    }

    private func paneWithAChromiumPage() async throws -> (AgentPaneView, FakeChromiumPage) {
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: true, chromium: hosting))
        let page = try #require(view.page)
        await page.chromiumStart?.value
        let chromium = try #require(hosting.made.first)
        view.loadingView.leave(over: view.pageContent, fades: false)
        return (view, chromium)
    }

    /// The 2 views fill the window's content, the second above the first.
    private func twoViewsAtOnePlace() async throws -> Place {
        _ = NSApplication.shared
        let (first, firstPage) = try await paneWithAChromiumPage()
        let (second, secondPage) = try await paneWithAChromiumPage()
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 300), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = host
        for pane in [first, second] {
            pane.frame = host.bounds
            pane.autoresizingMask = [.width, .height]
            host.addSubview(pane)
        }
        host.layoutSubtreeIfNeeded()
        let pageWindow = NSWindow(contentRect: window.convertToScreen(host.convert(host.bounds, to: nil)), styleMask: [.borderless], backing: .buffered, defer: true)
        pageWindow.isReleasedWhenClosed = false
        window.addChildWindow(pageWindow, ordered: .above)
        let place = Place(first: first, second: second, firstPage: firstPage, secondPage: secondPage, window: window, host: host, pageWindow: pageWindow)
        try #require(pageWindow.parent === window, "setup: the page window is no child window of the window")
        try #require(place.isUnderThePageWindow(first) && place.isUnderThePageWindow(second),
                     "setup: the Chromium content view of each of the 2 views is not under the page window's centre")
        return place
    }

    /// Starts a paint hold in the place's host: `outgoing` stays shown, and the second view waits above it in a view at
    /// alpha 0. At the hold's end `outgoing` is hidden, as a pane hides the view that it leaves.
    private func paintHold(in place: Place, outgoing: NSView) throws -> (PanePaintHold, NSView) {
        let incoming = Incoming(frame: place.host.bounds)
        incoming.autoresizingMask = [.width, .height]
        place.host.addSubview(incoming)
        place.second.frame = incoming.bounds
        incoming.addSubview(place.second)
        place.host.layoutSubtreeIfNeeded()
        try #require(place.isUnderThePageWindow(place.second), "setup: the second view is not under the page window's centre in the hold's view")
        let hold = PanePaintHold(owner: "test.page-window.paint-hold")
        hold.begin(outgoing: outgoing, incoming: incoming, in: place.host, release: { $0.isHidden = true })
        try #require(incoming.alphaValue == 0 && !place.second.isHiddenOrHasHiddenAncestor && !outgoing.isHiddenOrHasHiddenAncestor,
                     "setup: in the hold the second view is not at alpha 0, or it or the view that stays is hidden")
        return (hold, incoming)
    }

    /// The pane shows one view and keeps the other as a hidden view at the same place (a tab that it showed before).
    /// Want: the shown view, whichever of the 2 is the later subview.
    @Test(arguments: [true, false]) func aHiddenViewAtThePlaceIsNotTheAnswer(theLaterViewIsHidden: Bool) async throws {
        let place = try await twoViewsAtOnePlace()
        defer { place.close() }
        let hidden = theLaterViewIsHidden ? place.second : place.first
        hidden.isHidden = true
        let which = theLaterViewIsHidden ? "later" : "earlier"
        let answer = place.answer(), want = theLaterViewIsHidden ? "the first view" : "the second view"
        print("AgentPaneUnderAPageWindowTests: row 1, the \(which) view of the place is hidden: the lookup answered \(answer), want \(want); "
            + "the app told Chromium last: \(place.told)")
        #expect(answer == want, "with the \(which) view hidden the lookup answered \(answer), want \(want)")
    }

    /// A paint hold: the pane shows the first view until the second painted. The second is above it, not hidden, at
    /// alpha 0, and the app tells Chromium that its page does not show. Want in the hold: the first view. Want after
    /// the hold's end: the second view.
    @Test func inAPaintHoldTheAnswerIsTheViewThatStillShows() async throws {
        let place = try await twoViewsAtOnePlace()
        defer { place.close() }
        let (hold, incoming) = try paintHold(in: place, outgoing: place.first)
        let inTheHold = place.answer(), told = place.told
        let toldFirst = place.firstPage.visibility.last, toldSecond = place.secondPage.visibility.last
        hold.end()
        try #require(place.first.isHidden && incoming.alphaValue == 1, "setup: the hold's end did not hide the first view and show the second")
        let after = place.answer()
        print("AgentPaneUnderAPageWindowTests: row 2, a paint hold: in the hold the lookup answered \(inTheHold), want the first view; "
            + "the app told Chromium then: \(told); after the hold's end the lookup answered \(after), want the second view")
        #expect(toldFirst == true && toldSecond == false, "in the hold the app did not tell Chromium that the first page shows and the second does not: \(told)")
        #expect(inTheHold == "the first view", "in the paint hold the lookup answered \(inTheHold), want the view that still shows")
        #expect(after == "the second view", "after the paint hold's end the lookup answered \(after), want the view that shows now")
    }

    /// A cold page in its paint hold with no agent page before it at the place: the pane showed a view that is no
    /// agent page (the first view is out of the window here). The app told no page of the place that it shows.
    /// Want in the hold: no view. A New Tab hold that asks then keeps the page window as what had the keyboard, and
    /// its take of a view does not make it forget that window (`NewTabHoldCloseKeyTests`).
    @Test func aColdPageInItsPaintHoldWithNoPageBeforeItIsNoAnswer() async throws {
        let place = try await twoViewsAtOnePlace()
        defer { place.close() }
        place.first.removeFromSuperview()
        let before = NSView(frame: place.host.bounds)
        place.host.addSubview(before, positioned: .below, relativeTo: place.second)
        let (hold, incoming) = try paintHold(in: place, outgoing: before)
        let inTheHold = place.answer(), told = place.told
        let toldFirst = place.firstPage.visibility.last, toldSecond = place.secondPage.visibility.last
        hold.end()
        try #require(before.isHidden && incoming.alphaValue == 1, "setup: the hold's end did not hide the view before the page and show the page")
        let after = place.answer()
        print("AgentPaneUnderAPageWindowTests: row 3, a cold page in its paint hold, no agent page before it: in the hold the lookup "
            + "answered \(inTheHold), want no view; the app told Chromium then: \(told); after the hold's end the lookup answered \(after), "
            + "want the second view")
        #expect(toldFirst == false && toldSecond == false, "in the hold the app told Chromium that a page of the place shows: \(told)")
        #expect(inTheHold == "no view", "in the paint hold of a cold page the lookup answered \(inTheHold), want no view: no page of the place shows")
        #expect(after == "the second view", "after the paint hold's end the lookup answered \(after), want the view that shows now")
    }

    /// A pane close that moves its panes: the pane that the close took out of the layout stays in the window, shown, to
    /// the end of the move, and the pane that takes its room grows over it. So 2 panes are at one place, and the app
    /// told Chromium for each that its page shows. The page window is the one of the pane that stays: the closed pane
    /// has no keyboard. Want: the lookup answers the view of the pane that stays, whichever host is the later subview.
    /// Then the host says that its pane leaves no more (a pane that a zoom covered comes back): the lookup finds its
    /// view again.
    ///
    /// Each host is a model (`PaneHost`): the first view is in the pane that stays, the second in the pane that leaves.
    /// The row sets the leaving state by hand; no close and no move run here.
    @Test(arguments: [true, false]) func aPaneThatLeftTheLayoutIsNotTheAnswer(theLeavingHostIsLater: Bool) async throws {
        let place = try await twoViewsAtOnePlace()
        defer { place.close() }
        let stays = PaneHost(frame: place.host.bounds), leaves = PaneHost(frame: place.host.bounds)
        for (host, pane) in [(stays, place.first), (leaves, place.second)] {
            host.autoresizingMask = [.width, .height]
            pane.frame = host.bounds
            host.addSubview(pane)
        }
        for host in theLeavingHostIsLater ? [stays, leaves] : [leaves, stays] { place.host.addSubview(host) }
        place.host.layoutSubtreeIfNeeded()
        try #require(place.isUnderThePageWindow(place.first) && place.isUnderThePageWindow(place.second),
                     "setup: the Chromium content view of each of the 2 panes is not under the page window's centre")
        try #require(place.firstPage.visibility.last == true && place.secondPage.visibility.last == true,
                     "setup: the app did not tell Chromium that each of the 2 pages shows: \(place.told)")
        leaves.isLeaving = true
        let inTheMove = place.answer()
        leaves.isLeaving = false
        let back = place.answer(), wantBack = theLeavingHostIsLater ? "the second view" : "the first view"
        let which = theLeavingHostIsLater ? "later" : "earlier"
        print("AgentPaneUnderAPageWindowTests: row 4, the host of the pane that leaves is the \(which) subview: while it leaves the lookup "
            + "answered \(inTheMove), want the first view; the app told Chromium then: \(place.told); with the host back in the layout "
            + "the lookup answered \(back), want \(wantBack)")
        #expect(inTheMove == "the first view", "with the \(which) host leaving the lookup answered \(inTheMove), want the view of the pane that stays")
        #expect(back == wantBack, "with the \(which) host back in the layout the lookup answered \(back), want \(wantBack)")
    }
}
