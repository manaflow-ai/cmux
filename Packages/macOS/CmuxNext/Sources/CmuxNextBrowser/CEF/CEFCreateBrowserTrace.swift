import CmuxNextSignposts

/// `cef.create_browser` (p09-observability 033): one async pair (AB/AE) around each Chromium browser the shim
/// is asked to build, role-aware: a window (`cmux_shim_create_window`, `cmux_shim_create_placeholder_window`)
/// or a tab joining a live window (`cmux_shim_tab_add`, `cmux_shim_tab_duplicate`).
///
/// - In process, the pair is the create call itself: `CefBrowserHost::CreateBrowser` (or the fork's tab insert)
///   holds the main thread there until OnAfterCreated (about 0.8 s for a window in a macOS 26 VM, `CEFSpareWindow`).
/// - In host mode the call only sends the request to the Chromium host, so the pair stays open until the host
///   answers it: its created reply (OnAfterCreated, `CEFRuntime.browserCreated`) or its refusal (CREATE_FAILED,
///   `CEFCreateFailure`), or until quit stops waiting for it.
///
/// An async pair, not a thread slice, because a host-mode create ends in a later turn and two panes' creates
/// can overlap, like Chrome's `TRACE_EVENT_NESTABLE_ASYNC_BEGIN0`/`END0` (base/trace_event/common/trace_event_common.h).
/// The begin record's `arg0` holds 1 in bit 0 for a spare window's placeholder, 1 in bit 1 for a tab that joins
/// a live window, and the profile index in bits 8-39 (``beginArg0(spare:joinsWindow:profileIndex:)``); an AB's
/// `arg1` is its async id. The ring holds numbers only, so a profile is its index here, never its id.
///
/// The runtime has one (`CEFSpareWindow.createTrace`, beside the window-build count).
final class CEFCreateBrowserTrace {
    /// What a host-mode create waits for: the answer naming its window request, or the browser id cmux minted
    /// for a tab (`tab_add`, `tab_duplicate`; the host's answer for it carries request 0).
    private enum Answer: Hashable {
        case window(Int32)
        case browser(Int32)

        init(browser: Int32, request: Int32) {
            self = request != 0 ? .window(request) : .browser(browser)
        }
    }

    private let signposter: Signposter
    /// Profile indexes handed out so far: the default profile is 0, others count from 1 in the order this
    /// runtime first built a window of theirs.
    private var profileIndexes: [BrowserProfileID: UInt32] = [:]
    /// Host-mode creates the host has not answered yet.
    private var awaitingAnswer: [Answer: SignpostInterval] = [:]

    /// - Parameter signposter: The `cef` category's signposter (tests pass one on their own trace runtime).
    init(signposter: Signposter = .cef) {
        self.signposter = signposter
    }

    /// Host-mode creates still waiting for the host's answer.
    var openCount: Int { awaitingAnswer.count }

    /// A begin record's `arg0`: `spare` in bit 0, `joinsWindow` in bit 1, `profileIndex` in bits 8-39.
    static func beginArg0(spare: Bool, joinsWindow: Bool = false, profileIndex: UInt32) -> UInt64 {
        (spare ? 1 : 0) | (joinsWindow ? 2 : 0) | UInt64(profileIndex) << 8
    }

    /// The number `profile` has in this runtime's records: 0 for the default profile, then 1, 2, ... in the
    /// order of each profile's first window.
    func profileIndex(of profile: BrowserProfileID) -> UInt32 {
        if profile == .default { return 0 }
        if let index = profileIndexes[profile] { return index }
        let index = UInt32(clamping: profileIndexes.count + 1)
        profileIndexes[profile] = index
        return index
    }

    /// Runs one shim window create (`body`, which returns the shim's 1 for started) inside a `cef.create_browser`
    /// pair. In process, or when the create did not start, the pair ends when `body` returns; in host mode a started
    /// create's pair ends at the host's answer for `request` (``answered(browser:request:)``).
    ///
    /// - Parameters:
    ///   - request: The window request the host's answer names.
    ///   - spare: Whether the window is a spare's placeholder (`CEFSpareWindow`).
    ///   - profile: The profile whose request context the window uses.
    ///   - hostMode: Whether the shim is the Chromium host's (`CEFRuntime.hostStart`).
    ///   - body: The shim create.
    /// - Returns: What `body` returned.
    func create(request: Int32, spare: Bool, profile: BrowserProfileID, hostMode: Bool, _ body: () -> Int32) -> Int32 {
        let interval = begin(spare: spare, joinsWindow: false, profile: profile, hostMode: hostMode)
        let started = body()
        finish(interval, awaiting: hostMode && started == 1 ? .window(request) : nil)
        return started
    }

    /// Runs one shim create of a tab that joins a live window (`body`: `tab_add` or `tab_duplicate`, which returns
    /// the new browser's id or 0) inside a `cef.create_browser` pair. It ends when `body` returns, except with a
    /// host that maps the ids cmux mints, whose answer for the returned id ends it (``answered(browser:request:)``).
    ///
    /// - Parameters:
    ///   - profile: The profile of the window the tab joins.
    ///   - hostMode: Whether the shim is the Chromium host's (`CEFRuntime.hostStart`).
    ///   - answeredByMintedID: Whether the host answers for the id `body` returns (`CEFPaneHost.createsBrowsersAtOnce`).
    ///   - body: The shim call.
    /// - Returns: What `body` returned.
    func addTab(profile: BrowserProfileID, hostMode: Bool, answeredByMintedID: Bool, _ body: () -> Int32) -> Int32 {
        let interval = begin(spare: false, joinsWindow: true, profile: profile, hostMode: hostMode)
        let browser = body()
        finish(interval, awaiting: answeredByMintedID && browser > 0 ? .browser(browser) : nil)
        return browser
    }

    /// The host answered a create: its created reply (every OnAfterCreated, a late one or one that comes during
    /// quit included) or its refusal (CREATE_FAILED). `request` is the window request, or 0 for a tab, which
    /// `browser` then names. Ends that create's pair; no effect in process, where the pair already ended.
    func answered(browser: Int32, request: Int32) {
        guard let interval = awaitingAnswer.removeValue(forKey: Answer(browser: browser, request: request)) else { return }
        signposter.end(.cefCreateBrowser, interval)
    }

    /// Quit stopped waiting for the host's answers (`CEFRuntime.shutdown`): ends every pair still open, so the ring
    /// never keeps a begin without its end.
    func endUnanswered() {
        for interval in awaitingAnswer.values { signposter.end(.cefCreateBrowser, interval) }
        awaitingAnswer.removeAll()
    }

    private func begin(spare: Bool, joinsWindow: Bool, profile: BrowserProfileID, hostMode: Bool) -> SignpostInterval {
        let index = profileIndex(of: profile)
        return signposter.begin(.cefCreateBrowser,
                                "spare=\(spare ? 1 : 0) joins=\(joinsWindow ? 1 : 0) profile=\(index) host=\(hostMode ? 1 : 0)",
                                arg0: Self.beginArg0(spare: spare, joinsWindow: joinsWindow, profileIndex: index))
    }

    /// Ends `interval` now, or keeps it open until the host's answer `answer` when there is one to wait for.
    private func finish(_ interval: SignpostInterval, awaiting answer: Answer?) {
        guard let answer else {
            signposter.end(.cefCreateBrowser, interval)
            return
        }
        // Request tokens and minted ids are never reused while their create is pending (`CEFRuntime.makeRequestToken`,
        // the remote shim's MintID).
        if let stale = awaitingAnswer.updateValue(interval, forKey: answer) { signposter.end(.cefCreateBrowser, stale) }
    }
}
