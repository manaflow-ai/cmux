/// The scripts native code runs in one page (``PageWebView/evaluate(_:whileFrozen:)``) and what each
/// does while the page is frozen (``PageFrozenPush``; plans/cmux-next/chrome-parity/p13-webui.md 3.C,
/// MQ12): a frozen page gets no script. A held push waits for the thaw, which runs the latest of each
/// kind once, in the order those were sent (a newer push of a kind moves it last), before anything
/// sent after it; a push that thaws first thaws the page in the caller's turn. A freeze starts with
/// nothing held, so pushes held for a document that ended while frozen (a discard, a Chromium page
/// that ended) never reach the next one.
///
/// ```swift
/// pushes.run(theme.applyScript, whileFrozen: .latest(.theme))   // the page's thaw runs it
/// ```
@MainActor
final class PageNativePushes {
    private struct Held {
        let kind: PagePushKind
        let script: String
    }

    private weak var page: PageWebView?
    private var held: [Held] = []
    /// Calls that wait for the page's answer now (``callStarted()``): while one runs, the page keeps
    /// ``PageLifecyclePlanner/KeepReason/pageCall`` and does not freeze.
    private(set) var callsInFlight = 0

    /// - Parameter page: The page the scripts run in (it owns this).
    init(_ page: PageWebView) {
        self.page = page
    }

    /// The scripts held for the thaw, in the order it runs them.
    var heldScripts: [String] { held.map(\.script) }

    /// Runs `script` in the page's main frame in whichever engine shows it, after the router
    /// envelopes waiting for the frame. While the page is frozen, `push` says whether it waits for
    /// the thaw or thaws the page first.
    ///
    /// - Returns: False when the script waits for the thaw (or the page is gone), true when it ran.
    @discardableResult
    func run(_ script: String, whileFrozen push: PageFrozenPush) -> Bool {
        guard let page else { return false }
        if page.frozenEngine != nil {
            switch push {
            case .latest(let kind):
                held.removeAll { $0.kind == kind }
                held.append(Held(kind: kind, script: script))
                return false
            case .thawsFirst:
                thawForCall()
            }
        }
        send(script, to: page)
        return true
    }

    /// A call that waits for the page's answer starts (``PageWebView/callPageScript(_:arguments:)``,
    /// ``PageWebView/callPageFunction(_:arguments:)``): the page thaws first, and does not freeze until
    /// the matching ``callEnded()``.
    func callStarted() {
        callsInFlight += 1
        thawForCall()
    }

    /// The call of one ``callStarted()`` has its answer: once none is left, the lifecycle looks at the
    /// page again and may freeze it.
    func callEnded() {
        guard callsInFlight > 0 else { return }
        callsInFlight -= 1
        guard callsInFlight == 0, let page else { return }
        page.loadState.lifecycle?.pageReasonsDidChange(page)
    }

    /// A freeze starts: nothing is held.
    func freezeStarted() {
        held.removeAll()
    }

    /// The page thawed (``PageWebView/thawPage()``): the held pushes run now.
    func thawed() {
        guard let page, !held.isEmpty else { return }
        let scripts = held
        held.removeAll()
        for entry in scripts { send(entry.script, to: page) }
    }

    /// A call that needs the page running reached it frozen (a ``PageFrozenPush/thawsFirst`` push, or a
    /// call that waits for the page's answer): it thaws in this turn through its lifecycle, which counts
    /// it hidden and freezes it again once no call runs and one recently visible window passed
    /// (``PageLifecycle/thawForCall(_:)``), or by itself when no lifecycle holds it. Nothing on a running page.
    func thawForCall() {
        guard let page, page.frozenEngine != nil else { return }
        page.loadState.lifecycle?.thawForCall(page)
        page.thawPage() // a no-op once the lifecycle thawed it
    }

    private func send(_ script: String, to page: PageWebView) {
        #if DEBUG || CMUX_BENCH_HOOKS
        if page.router.debugPageHidden { page.censusState.pushesWhileHidden &+= 1 }
        #endif
        page.scripts.flush()
        page.scriptTarget.evaluate(script)
    }
}
