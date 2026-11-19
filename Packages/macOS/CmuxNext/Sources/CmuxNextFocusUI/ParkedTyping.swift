public import AppKit

/// A page that parked text is typed into (the app's page input readiness).
@MainActor
public protocol ParkedTypingPage: AnyObject, Sendable {
    /// The number of the page's focus state. An insertion that names it goes only into the field that had the focus then.
    var focusEpoch: Int { get }
    /// Types `text` into the focused field as one insertion.
    ///
    /// - Returns: Whether a field took the text.
    func insert(_ text: String, expectedEpoch: Int?) async -> Bool
    /// Runs `work` each time the page turns ready for typing, and now when it already is.
    func whenReady(_ work: @escaping () -> Void)
}

/// What the park reads and calls of the key router that owns it.
@MainActor
public protocol ParkedTypingRouter: AnyObject {
    associatedtype Page: ParkedTypingPage
    associatedtype HeldKey
    /// The surface of the page that the queue's text is on its way into. Nil when none is.
    var deliveringTypeAhead: String? { get }
    /// The keys from a Return on that wait behind a page's text.
    var typeAheadTail: TypeAheadTail<HeldKey> { get set }
    /// The input event in dispatch.
    var inputDispatch: InputDispatchContext { get }
    /// Types what waits for `readiness` into it, in the order of the keys.
    func flushTypeAhead(_ surface: String, into readiness: Page)
}

/// The key router's park for the text that a New Tab page waits for when the next New Tab key comes (New Tab key, a
/// letter, New Tab key, fast). A key with Command or Control ends the router's type-ahead queue, and the queue keeps
/// the text of one page, so that letter was lost. It is parked now, and it is typed into its own page when the field
/// of that page reports ready (``TypingPark`` has the rules and the counts).
///
/// One rule says what is parked, with no list of actions: the text that a key with Command or Control took out of
/// the queue is parked only when, while that same key is in dispatch, a New Tab page opens in the pane that shows the
/// text's page (the app tells it after the opening's key hold began). Each other key with Command or Control drops
/// the text, as before: a key that opens a terminal, a browser or a chat tab, a tab switch, Paste, Close Tab.
///
/// A surface is the name of a page object in the router's queue (the text of its object identifier).
@MainActor
public final class ParkedTyping<Router: ParkedTypingRouter> {
    /// The text that a key with Command or Control took out of the queue. It is kept until the next such key, and it
    /// counts only while its own key is in dispatch.
    private struct Taken {
        let event: NSEvent
        let text: String
        /// The surface of the page that the text waited for.
        let surface: String
        /// How many keys from a Return on waited behind the text.
        let returns: Int
    }

    private weak var router: Router?
    /// The texts that wait for their pages, and what became of each.
    public private(set) var park = TypingPark<Router.Page>()
    private var taken: Taken?
    /// The park's clock (tests pass their own).
    public var now: () -> ContinuousClock.Instant = { ContinuousClock.now }

    /// - Parameter router: The key router that owns the park. The park keeps it weakly.
    public init(router: Router) {
        self.router = router
    }

    nonisolated deinit {} // a main-actor class with a type parameter: its implicit deinit crashes the optimizer of the Release build

    /// What became of the parked texts since the park was made, by the names of `debug.focus`. Counts only.
    public func counts() -> [String: Int] {
        park.prune(now: now())
        return park.counts.named
    }

    /// Whether a text waits for `page` or is on its way into it, for a key in that page. A text that waited the limit
    /// is dropped and counted first: it is not typed, so it holds no key behind it. With nothing parked the answer is
    /// false with no read of the clock.
    public func holds(_ page: Router.Page) -> Bool {
        guard !park.isEmpty else { return false }
        park.prune(now: now())
        return park.holds(page)
    }

    /// The key with Command or Control `event` ends the queue. The text that waits in the queue is kept until the next
    /// such key, and it counts only while this key is in dispatch (``newTabPageOpens(showing:)``).
    ///
    /// - Parameters:
    ///   - event: The key-down in dispatch.
    ///   - text: The queue's text before the key drops it.
    ///   - surface: The surface that the text waits for. Nil when the queue is empty.
    public func keyEndsQueue(_ event: NSEvent, text: String, for surface: String?) {
        taken = nil
        guard let router, let surface, !text.isEmpty else { return }
        taken = Taken(event: event, text: text, surface: surface, returns: router.typeAheadTail.count(behind: surface))
    }

    /// A New Tab page opens in a pane, and its key hold began. When the key in dispatch took text out of the queue
    /// for `page`, that text is parked for it.
    ///
    /// - Parameter page: The page that the pane shows at the opening, before the new tab. Nil when it has none.
    public func newTabPageOpens(showing page: Router.Page?) {
        guard let router, let held = taken, held.event === router.inputDispatch.event, let page,
              String(describing: ObjectIdentifier(page)) == held.surface else { return }
        taken = nil
        park.park(held.text, for: page, droppingReturns: held.returns, now: now())
        let surface = held.surface
        // The page's report runs the router's flush for the page, and the flush types the parked text first.
        page.whenReady { [weak router, weak page] in page.map { router?.flushTypeAhead(surface, into: $0) } }
    }

    /// Types the text that is parked for `page` into it. The router's flush calls it first: at the page's report,
    /// and after each text that landed in the page. A text of the queue that is on its way into the page goes first.
    ///
    /// - Returns: True while a parked text is on its way into the page: the queue's text for the page goes after it.
    public func types(_ surface: String, into page: Router.Page) -> Bool {
        guard let router, router.deliveringTypeAhead != surface else { return false }
        if park.isOnItsWay(to: page) { return true }
        guard let text = park.take(for: page, now: now()) else { return false }
        router.typeAheadTail.textWasTaken(surface: surface) // a Return typed into the page after the park follows the text
        let epoch = page.focusEpoch
        // task-owner: one parked insertion into its page; the router's flush for the page runs after it
        Task { [weak self] in
            var typed = await page.insert(text, expectedEpoch: epoch)
            // The page moved its focus while the text was on its way, and refused it for the old focus count (a
            // New Tab page whose host failed shows its chat view, and the composer takes the focus): one more
            // time, for the field that has the focus now.
            if !typed, page.focusEpoch != epoch { typed = await page.insert(text, expectedEpoch: page.focusEpoch) }
            guard let self else { return }
            self.park.landed(in: page, typed: typed)
            guard let router = self.router else { return }
            // A Return alone would act on a field that its text never reached.
            if !typed, router.typeAheadTail.holds(surface) { router.typeAheadTail.drop() }
            router.flushTypeAhead(surface, into: page)
        }
        return true
    }
}
