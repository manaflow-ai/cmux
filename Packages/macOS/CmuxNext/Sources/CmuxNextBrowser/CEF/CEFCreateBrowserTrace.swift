import CmuxNextSignposts

/// `cef.create_browser` (p09-observability 033): one async pair (AB/AE) around each Chromium window the shim
/// is asked to build (`cmux_shim_create_window`, `cmux_shim_create_placeholder_window`), role-aware.
///
/// - In process, the pair is the create call itself: `CefBrowserHost::CreateBrowser` and the `NSWindow` it
///   builds hold the main thread there (about 0.8 s in a macOS 26 VM, `CEFSpareWindow`).
/// - In host mode the call only sends the request to the Chromium host, so the pair stays open until the
///   host's created reply (OnAfterCreated, `CEFRuntime.browserCreated`) for its window request, or until quit
///   stops waiting for it.
///
/// An async pair, not a thread slice, because a host-mode create ends in a later turn and two panes' creates
/// can overlap, like Chrome's `TRACE_EVENT_NESTABLE_ASYNC_BEGIN0`/`END0` (base/trace_event/common/trace_event_common.h).
/// The begin record's `arg0` holds 1 in bit 0 for a spare window's placeholder and the profile index in bits
/// 8-39 (``beginArg0(spare:profileIndex:)``); an AB's `arg1` is its async id. The ring holds numbers only, so a
/// profile is its index here, never its id.
///
/// The runtime has one (`CEFSpareWindow.createTrace`, beside the window-build count).
final class CEFCreateBrowserTrace {
    private let signposter: Signposter
    /// Profile indexes handed out so far: the default profile is 0, others count from 1 in the order this
    /// runtime first built a window of theirs.
    private var profileIndexes: [BrowserProfileID: UInt32] = [:]
    /// Host-mode creates the host has not answered yet, by window request.
    private var awaitingReply: [Int32: SignpostInterval] = [:]

    /// - Parameter signposter: The `cef` category's signposter (tests pass one on their own trace runtime).
    init(signposter: Signposter = .cef) {
        self.signposter = signposter
    }

    /// Host-mode creates still waiting for the host's created reply.
    var openCount: Int { awaitingReply.count }

    /// A begin record's `arg0`: `spare` in bit 0, `profileIndex` in bits 8-39.
    static func beginArg0(spare: Bool, profileIndex: UInt32) -> UInt64 {
        (spare ? 1 : 0) | UInt64(profileIndex) << 8
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

    /// Runs one shim create (`body`, which returns the shim's 1 for started) inside a `cef.create_browser` pair.
    /// In process, or when the create did not start, the pair ends when `body` returns; in host mode a started
    /// create's pair ends at ``created(request:)``.
    ///
    /// - Parameters:
    ///   - request: The window request the created reply names.
    ///   - spare: Whether the window is a spare's placeholder (`CEFSpareWindow`).
    ///   - profile: The profile whose request context the window uses.
    ///   - hostMode: Whether the shim is the Chromium host's (`CEFRuntime.hostStart`).
    ///   - body: The shim create.
    /// - Returns: What `body` returned.
    func create(request: Int32, spare: Bool, profile: BrowserProfileID, hostMode: Bool, _ body: () -> Int32) -> Int32 {
        let index = profileIndex(of: profile)
        let interval = signposter.begin(.cefCreateBrowser, "spare=\(spare ? 1 : 0) profile=\(index) host=\(hostMode ? 1 : 0)",
                                        arg0: Self.beginArg0(spare: spare, profileIndex: index))
        let started = body()
        guard hostMode, started == 1 else {
            signposter.end(.cefCreateBrowser, interval)
            return started
        }
        // A request token is never reused while its window is pending (`CEFRuntime.makeRequestToken`).
        if let stale = awaitingReply.updateValue(interval, forKey: request) { signposter.end(.cefCreateBrowser, stale) }
        return started
    }

    /// The host's created reply for `request` (every OnAfterCreated for a window request: a late one, or one
    /// that comes during quit, included): ends that create's pair. No effect in process, where the pair already ended.
    func created(request: Int32) {
        guard let interval = awaitingReply.removeValue(forKey: request) else { return }
        signposter.end(.cefCreateBrowser, interval)
    }

    /// Quit stopped waiting for the host's replies (`CEFRuntime.shutdown`): ends every pair still open, so the ring
    /// never keeps a begin without its end.
    func endUnanswered() {
        for interval in awaitingReply.values { signposter.end(.cefCreateBrowser, interval) }
        awaitingReply.removeAll()
    }
}
