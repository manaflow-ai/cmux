public import AppKit
public import CmuxNextDesign
public import WebKit

// A cmux page in Chromium costs nothing while nobody sees it (speed-of-sound-DESIGN.md 3.1 and 3.3,
// perf-lead.md F3), in two steps:
//
// - No renderer before the first show. Its Chromium page, and with it a renderer process, starts
//   when the view first shows: in a window, neither it nor an ancestor hidden or parked
//   (``AppKit/NSView/isParkedOrHasParkedAncestor``). A page made for a tab that is not selected, a
//   workspace that is not shown, or a restore makes no renderer until it shows, unless its owner
//   has work only the page can do and starts it at once (``startWithoutShowing()``). The host makes
//   the CEF tab on a later display frame, one page per frame, never in the frame of the action that
//   showed it (``ChromiumPageFrameBudget``).
// - Frozen after a grace while hidden. A started page that hides stops drawing at once and keeps
//   running (it boots and takes its pushes, as a WebKit page does); once it has stayed hidden for
//   the hibernation's grace with no call or push from the host, the policy freezes it
//   (``PageFreezePolicy``, ``freezeWhileHidden()``). It thaws before it shows and before any call
//   or push reaches its document (``awakeChromiumPage``, the bridge's `willSend`), and that
//   restarts its grace.
//
// A view in an alpha-0 container that is not a ``ParkingContainer`` (the New Tab spare's parking, a
// paint hold) counts as shown: it must draw at its size before it is adopted.
extension PageWebView {
    /// Whether the page shows for Chromium's purposes: in a window, not hidden and not parked.
    var isShownForChromium: Bool { window != nil && !isHiddenOrHasHiddenAncestor && !isParkedOrHasParkedAncestor }

    /// In Chromium mode the new view waits for its first show with no document in either engine
    /// (true); otherwise it does nothing (false) and the caller loads the WebKit page. A waiting
    /// view's WebKit view stays hidden and takes no script (``PageScriptTarget``), so it starts no
    /// web content process; the Chromium page loads ``route`` as it stands when it starts.
    func waitsForFirstShow(_ hosting: (any PageChromiumHosting)?) -> Bool {
        guard engineDecision.engine == .cef, let hosting else { return false }
        chromiumAwaitingShow = hosting
        webView.isHidden = true
        scriptTarget.bridge = nil
        inputReadiness.inserter = { _ in false }
        chromiumShownChanged()
        return true
    }

    /// Starts a Chromium page that waits for its first show now, shown or not.
    ///
    /// For an owner whose page must run before anyone sees it: a chat opened out of sight with a
    /// prompt that goes out by itself or an adopt, which only the page sends, and which would
    /// otherwise wait for the first show (or be lost when the app quits first). Does nothing when
    /// the page already started or shows in WebKit.
    public func startWithoutShowing() {
        guard let hosting = chromiumAwaitingShow else { return }
        chromiumAwaitingShow = nil
        startAwaitedPage(hosting: hosting)
    }

    /// Starts a page that waited for its first show, in the engine the policy picks now: the wait
    /// can be hours (a restored tab), and since then the person may have chosen WebKit or Chromium
    /// may have become unavailable (the crash-loop gate, a missing runtime pack). Such a page opens
    /// in WebKit directly, with no Chromium start that fails first.
    private func startAwaitedPage(hosting: any PageChromiumHosting) {
        let decision = Self.engineDecision(for: descriptor, options: engineOptions, hosting: hosting)
        guard decision.engine == .cef else {
            showInWebKit(decision)
            return
        }
        startChromium(hosting: hosting)
    }

    /// Freezes the started page while it stays hidden: its timers, tasks, React effects and
    /// rendering stop until it shows or the host calls it. Called by the ``PageFreezePolicy`` once
    /// the page has been hidden for its grace; does nothing for a page that shows, has not reached
    /// the host yet (it still boots), is frozen already or is not in Chromium.
    ///
    /// - Returns: True when the page froze now.
    @discardableResult
    public func freezeWhileHidden() -> Bool {
        chromiumSession?.freeze() ?? false
    }

    /// Whether the page shows in Chromium and waits for its first show to start (no renderer yet).
    public var isWaitingForFirstShow: Bool { chromiumAwaitingShow != nil }

    /// Whether the hibernation froze the page (``freezeWhileHidden()``).
    public var isChromiumFrozen: Bool { chromiumSession?.frozen ?? false }

    /// The view joined or left a window or a superview, or it or an ancestor hid, showed, parked or
    /// unparked: the first show starts the Chromium page, and a started page shows or hides.
    func chromiumShownChanged() {
        let shown = isShownForChromium
        if shown, let hosting = chromiumAwaitingShow {
            chromiumAwaitingShow = nil
            startAwaitedPage(hosting: hosting)
        }
        if let chromiumSession { showChromium(chromiumSession, shown) }
    }

    /// Shows or hides the started page (a frozen page thaws first) and tells the freeze policy.
    func showChromium(_ session: PageChromiumSession, _ shown: Bool) {
        guard session.show(shown) else { return }
        if shown {
            session.freezePolicy?.pageIsNoLongerHidden(self)
        } else {
            session.freezePolicy?.hiddenPageWoke(self)
        }
    }

    /// The host is about to reach into the page (a call, a push, a reply): a frozen page thaws,
    /// and a hidden page's grace starts again, so a page the host keeps feeding stays awake.
    func wake(_ session: PageChromiumSession) {
        session.thaw()
        if session.isHidden { session.freezePolicy?.hiddenPageWoke(self) }
    }

    /// The Chromium page, awake, for a call into its document; nil while WebKit shows the page or
    /// the Chromium page has not started. Every DevTools call into the document goes through here:
    /// a frozen page runs no script, so the call would wait until the next show.
    var awakeChromiumPage: (any PageChromiumPage)? {
        guard let chromiumSession else { return nil }
        wake(chromiumSession)
        return chromiumSession.page
    }

    /// The WebKit view while WebKit shows the document; nil in Chromium mode, also while the
    /// Chromium page waits for its first show or starts.
    ///
    /// A call meant for the document goes here, never to ``webKitView``: a script or a load sent to
    /// an unused WebKit view starts a WebKit web content process for a page WebKit never shows.
    public var documentWebView: WKWebView? { engineDecision.engine == .webKit ? webView : nil }

    /// The page shows in Chromium but its Chromium page has not started (it waits for its first
    /// show): there is no document to call.
    var awaitsChromiumStart: Bool { engineDecision.engine == .cef && chromiumSession == nil }
}

extension PageWebView: ParkingObserver {
    /// A container above parked or unparked (``ParkingContainer``): the page starts on its first
    /// show, and a started page shows or hides, as for a hide.
    public func parkingDidChange() {
        chromiumShownChanged()
    }
}
