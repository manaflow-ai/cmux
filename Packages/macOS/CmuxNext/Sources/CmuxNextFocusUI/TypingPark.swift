/// Text for a page that its pane no longer shows. A person types into a new tab whose page cannot take keys yet,
/// and then presses the New Tab key again. The key router's type-ahead queue keeps the text of one page, and a key
/// with Command or Control ends it, so that text was lost. It waits here, by its page, and it is typed into that
/// page when the page's field reports ready.
///
/// The rules:
/// - A text waits for one page object. A page that is gone takes its text with it.
/// - A text that waited `limit` or longer from the key that parked it is dropped. The limit counts from that key,
///   not from the keys of the text.
/// - Two texts for one page are typed in the order of their keys: the second waits until the first landed.
/// - The keys from a Return on that waited behind a text are not parked. The text stands in its field, and it is not
///   sent in a tab that the person does not see.
///
/// Each text that leaves the park adds to one count (``Counts``). The counts hold no characters.
///
/// `Page` is the page object (the app: the page's input readiness; a test: any object). The park keeps it weakly.
///
/// ```swift
/// var park = TypingPark<Page>()
/// park.park("x", for: page, now: start)
/// park.take(for: page, now: start + .milliseconds(300)) // "x", once: it is on its way
/// park.landed(in: page, typed: true)
/// ```
public nonisolated struct TypingPark<Page: AnyObject> {
    /// What became of the parked texts since the park was made.
    public nonisolated struct Counts: Equatable, Sendable {
        /// Texts that came into the park.
        public var parked = 0
        /// Texts that were typed into their page.
        public var typed = 0
        /// Texts that waited the limit or longer.
        public var droppedOld = 0
        /// Texts whose page was gone.
        public var droppedPageGone = 0
        /// Texts that the field of their page refused.
        public var droppedRefused = 0
        /// Keys from a Return on (the Return and each key behind it) that waited behind a text at its park.
        public var droppedReturns = 0

        public init() {}

        /// The counts by their names in `debug.focus`.
        public var named: [String: Int] {
            ["parked": parked, "typed": typed, "dropped_old": droppedOld, "dropped_page_gone": droppedPageGone,
             "dropped_refused": droppedRefused, "dropped_returns": droppedReturns]
        }
    }

    private nonisolated struct Entry {
        weak var page: Page?
        let text: String
        /// The time of the key that parked the text.
        let since: ContinuousClock.Instant
        /// The text was taken for its page and did not land yet.
        var onItsWay: Bool
    }

    private var entries: [Entry] = []
    /// What became of the parked texts.
    public private(set) var counts = Counts()
    /// How long a text waits for its page, from the key that parked it.
    public let limit: Duration

    /// - Parameter limit: How long a text waits for its page, from the key that parked it.
    public init(limit: Duration = .seconds(2)) {
        self.limit = limit
    }

    /// Whether the park has no text: none waits and none is on its way.
    public var isEmpty: Bool { entries.isEmpty }

    /// Whether a text waits for `page` or is on its way into it. It reads no clock: a text that waited the limit
    /// counts until ``prune(now:)`` drops it.
    public func holds(_ page: Page) -> Bool {
        entries.contains { $0.page === page }
    }

    /// Whether a text that was taken for `page` is on its way into it.
    public func isOnItsWay(to page: Page) -> Bool {
        entries.contains { $0.onItsWay && $0.page === page }
    }

    /// Parks `text` for `page` at `now`, the time of the key that ended the queue.
    ///
    /// - Parameters:
    ///   - text: The text that waited for the page.
    ///   - page: The page object that the text waited for.
    ///   - returns: How many keys from a Return on waited behind the text. They are dropped and counted.
    ///   - now: The time of the key that parks the text.
    public mutating func park(_ text: String, for page: Page, droppingReturns returns: Int = 0, now: ContinuousClock.Instant) {
        prune(now: now)
        entries.append(Entry(page: page, text: text, since: now, onItsWay: false))
        counts.parked += 1
        counts.droppedReturns += returns
    }

    /// The oldest text that waits for `page`, once: it is on its way then, until ``landed(in:typed:)``.
    ///
    /// - Returns: Nil when no text waits for the page, when a text for the page is on its way, or when the text
    ///   waited the limit or longer (it is dropped then).
    public mutating func take(for page: Page, now: ContinuousClock.Instant) -> String? {
        prune(now: now)
        guard let index = entries.firstIndex(where: { $0.page === page }), !entries[index].onItsWay else { return nil }
        entries[index].onItsWay = true
        return entries[index].text
    }

    /// The text that was taken for `page` landed in its field (`typed`), or the field refused it.
    public mutating func landed(in page: Page, typed: Bool) {
        guard let index = entries.firstIndex(where: { $0.onItsWay && $0.page === page }) else { return }
        entries.remove(at: index)
        if typed { counts.typed += 1 } else { counts.droppedRefused += 1 }
    }

    /// Drops each text whose page is gone, and each waiting text that waited the limit or longer at `now`, with its
    /// count.
    public mutating func prune(now: ContinuousClock.Instant) {
        var gone = 0, old = 0
        let limit = self.limit
        entries.removeAll { entry in
            if entry.page == nil {
                gone += 1
                return true
            }
            guard !entry.onItsWay, now - entry.since >= limit else { return false }
            old += 1
            return true
        }
        counts.droppedPageGone += gone
        counts.droppedOld += old
    }
}
