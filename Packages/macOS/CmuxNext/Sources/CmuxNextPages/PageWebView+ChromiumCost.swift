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
//   showed it (the app's `ChromiumPageFrameBudget`).
// - Frozen after a grace while nobody sees it: hidden, parked, out of a window, or in a window that
//   is covered, minimized or ordered out (``WindowOcclusionFamily``, ``WindowDrawPolicy``). A
//   started page that hides stops drawing at once and keeps running (it boots and finishes what it
//   was asked); once it said it booted, no page message is being handled and it stayed unseen for
//   the hibernation's grace, the policy freezes it (``PageFreezePolicy``, ``freezeWhileHidden()``).
//   While it is frozen nothing goes into it and nothing thaws it but a need: its streams' events
//   wait by their ``PageStreamFreezing`` (the newest state goes at the thaw), the theme, scale,
//   attribute and glass scripts are sent again at the thaw, and only an event that cannot wait, a
//   host call or a script, a show or the owner thaws it.
//
// A view in an alpha-0 container that is not a ``ParkingContainer`` (the New Tab spare's parking, a
// paint hold) counts as shown: it must draw at its size before it is adopted.
extension PageWebView {
    /// Whether the page shows for Chromium's purposes: in a window, not hidden and not parked.
    var isShownForChromium: Bool { window != nil && !isHiddenOrHasHiddenAncestor && !isParkedOrHasParkedAncestor }

    /// Whether anybody can see the page: it shows, and its window is on screen (not covered,
    /// minimized, ordered out or on another Space; automation launches count every window seen).
    var isSeenForChromium: Bool { isShownForChromium && WindowDrawPolicy.isDrawable(window) }

    /// In Chromium mode the new view waits for its first show with no document in either engine
    /// (true); otherwise it does nothing (false) and the caller loads the WebKit page. A waiting
    /// view's WebKit view stays hidden and takes no script (``PageScriptTarget``), so it starts no
    /// web content process; the Chromium page loads ``route`` as it stands when it starts.
    func waitsForFirstShow(_ hosting: (any PageChromiumHosting)?) -> Bool {
        guard engineDecision.engine == .cef, let hosting else { return false }
        chromiumAwaitingShow = hosting
        webView.isHidden = true
        scriptTarget.bridge = nil
        inputReadiness.editor = { _, _ in false }
        router.onBooted = { [weak self] in self?.chromiumBooted() }
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
        startChromium(hosting: hosting)
    }

    /// Freezes the started page while nobody sees it: its timers, tasks, React effects and
    /// rendering stop, and no push goes into it, until it is seen or something needs it. Called by
    /// the ``PageFreezePolicy`` once the page has been unseen for its grace.
    ///
    /// Does nothing for a page that is seen, has not said it booted, has a message of its own or a
    /// host call still waiting (the page waits on the host, or the host on it), is frozen already,
    /// or is not in Chromium; the page reports to the policy again when that ends.
    ///
    /// - Returns: True when the page froze now.
    @discardableResult
    public func freezeWhileHidden() -> Bool {
        guard let session = chromiumSession, session.isHidden, session.booted, !session.frozen,
              session.handlingMessages == 0, !router.awaitsPageReplies else { return false }
        session.freeze()
        router.freeze { [weak self, weak session] in
            guard let self, let session, self.chromiumSession === session else { return }
            self.wake(session)
        }
        onChromiumFrozenChange?(true)
        return true
    }

    /// Thaws a frozen page that stays hidden, for its owner (a chat whose turn started: it works
    /// while hidden). Its grace starts again; nothing for a live page.
    public func thawWhileHidden() {
        guard let chromiumSession else { return }
        wake(chromiumSession)
    }

    /// Whether the page shows in Chromium and waits for its first show to start (no renderer yet).
    public var isWaitingForFirstShow: Bool { chromiumAwaitingShow != nil }

    /// Whether the hibernation froze the page (``freezeWhileHidden()``).
    public var isChromiumFrozen: Bool { chromiumSession?.frozen ?? false }

    /// Where the page is in its Chromium life, read without calling into it (`debug.page list`,
    /// bench_idle.py): `webkit`, `waiting` (no renderer until its first show), `starting`, `frozen`,
    /// `hidden` (unseen and awake) or `seen`.
    public var chromiumLifecycle: String {
        guard engineDecision.engine == .cef else { return "webkit" }
        if chromiumAwaitingShow != nil { return "waiting" }
        guard let session = chromiumSession else { return "starting" }
        if session.frozen { return "frozen" }
        return session.isHidden ? "hidden" : "seen"
    }

    /// The view joined or left a window or a superview, it or an ancestor hid, showed, parked or
    /// unparked, or its window's occlusion changed: the first show starts the Chromium page, and a
    /// started page shows or hides.
    func chromiumShownChanged() {
        if isShownForChromium, let hosting = chromiumAwaitingShow {
            chromiumAwaitingShow = nil
            startChromium(hosting: hosting)
        }
        if let chromiumSession { showChromium(chromiumSession) }
    }

    /// Shows or hides the started page (a frozen page thaws before it is seen) and tells the freeze
    /// policy when it is seen or not.
    func showChromium(_ session: PageChromiumSession) {
        let seen = isSeenForChromium
        if seen { thaw(session) }
        session.setShown(isShownForChromium)
        guard session.setSeen(seen) else { return }
        if seen {
            session.freezePolicy.pageIsNoLongerHidden(self)
        } else {
            session.freezePolicy.hiddenPageWoke(self)
        }
    }

    /// The page's document finished its start (its client's `booted`): an unseen page's grace
    /// starts now.
    func chromiumBooted() {
        guard let chromiumSession else { return }
        chromiumSession.booted = true
        noteHiddenActivity(chromiumSession)
    }

    /// A page message starts (`ended` false) or its reply went (`ended` true): the page is busy
    /// with the host, so an unseen page's grace starts again when it ends.
    func noteChromiumMessage(_ session: PageChromiumSession, ended: Bool) {
        session.handlingMessages += ended ? -1 : 1
        if ended, chromiumSession === session { noteHiddenActivity(session) }
    }

    /// The host is about to reach into the page (a call, a script, an event that cannot wait): a
    /// frozen page thaws, and an unseen page's grace starts again.
    func wake(_ session: PageChromiumSession) {
        thaw(session)
        noteHiddenActivity(session)
    }

    /// An unseen page did something: its grace starts again (nothing while it is frozen).
    private func noteHiddenActivity(_ session: PageChromiumSession) {
        guard session.isHidden, !session.frozen else { return }
        session.freezePolicy.hiddenPageWoke(self)
    }

    /// Thaws a frozen page: Chromium first (so what follows runs) and its visibility again (a freeze
    /// hid it), then the events its streams kept (one per key), then the document's state if a
    /// script of it was skipped.
    private func thaw(_ session: PageChromiumSession) {
        guard session.thaw(shown: isShownForChromium) else { return }
        router.thaw()
        if session.stateStale {
            session.stateStale = false
            refreshDocumentState()
        }
        onChromiumFrozenChange?(false)
    }

    /// Sends a script that sets the document's state (theme, interface scale, `data-*` attributes,
    /// glass): skipped while the page is frozen, which sends the whole state again when it thaws.
    func evaluateDocumentState(_ script: String) {
        if let chromiumSession, chromiumSession.frozen {
            chromiumSession.stateStale = true
            return
        }
        scriptTarget.evaluate(script)
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

extension PageWebView: ParkingObserver, WindowOcclusionFollowing {
    /// A Chromium page freezes while its window is covered, minimized or ordered out too: it
    /// follows its window's occlusion (one observer per window, ``WindowOcclusionFamily``).
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard engineDecision.engine == .cef, newWindow !== window else { return }
        window.map { WindowOcclusionFamily.of($0) }?.remove(self)
        newWindow.map { WindowOcclusionFamily.of($0) }?.add(self)
    }

    /// A container above parked or unparked (``ParkingContainer``): the page starts on its first
    /// show, and a started page shows or hides, as for a hide.
    public func parkingDidChange() {
        chromiumShownChanged()
    }

    /// The window was covered, minimized or ordered out, or came back: an unseen page's grace
    /// starts, a seen one thaws.
    public func windowOcclusionDidChange() {
        chromiumShownChanged()
    }
}
