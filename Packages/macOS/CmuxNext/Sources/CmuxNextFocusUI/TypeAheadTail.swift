/// The keys that follow a page's queued type-ahead text and are not text: Return first, then every
/// key typed after it. They wait, in typing order, until the text landed in the page, and run
/// then as typed. Before, Return ended the queue: the text typed into a page whose field was not
/// ready was dropped and Return acted on an empty field ("I type in something and press Enter and
/// if it's too early nothing happens", Lawrence 2026-11-10).
///
/// `Key` is the held key (the app holds the event and its window; a test, any value).
public nonisolated struct TypeAheadTail<Key> {
    /// The surface the keys wait for; nil when none wait.
    public private(set) var surface: String?
    private var keys: [Key] = []
    /// The text the keys follow was taken for the page (it is on its way, or landed).
    private var textTaken = false

    public init() {}

    /// Whether keys wait behind `surface`'s text.
    public func holds(_ surface: String) -> Bool { self.surface == surface && !keys.isEmpty }

    public var isEmpty: Bool { keys.isEmpty }

    /// Whether a key typed now waits here. Return or keypad Enter starts the tail when it follows
    /// queued text (`behindText`); every later key joins it, except Escape (it cancels what waits).
    /// A chord never waits: it ends the queue.
    public func takes(keyCode: UInt16, chord: Bool, surface: String, behindText: Bool) -> Bool {
        guard !chord else { return false }
        if holds(surface) { return keyCode != 53 }
        return behindText && (keyCode == 36 || keyCode == 76)
    }

    /// Holds `key` behind `surface`'s text. `delivering`: that text was already taken for the page.
    /// Keys held for another surface are dropped first: its page is no longer the one typed into.
    public mutating func hold(_ key: Key, surface: String, delivering: Bool) {
        if self.surface != surface { drop() }
        self.surface = surface
        keys.append(key)
        if delivering { textTaken = true }
    }

    /// `surface`'s queued text was taken for the page: the held keys follow it.
    public mutating func textWasTaken(surface: String) {
        if self.surface == surface, !keys.isEmpty { textTaken = true }
    }

    /// Nothing more is on its way to `surface`: the held keys, once, in typing order. Empty when
    /// their text never reached the page (it expired in the queue): a key alone would act on an
    /// empty field, so they are dropped with it.
    public mutating func settle(surface: String) -> [Key] {
        guard self.surface == surface else { return [] }
        let run = textTaken ? keys : []
        drop()
        return run
    }

    /// The text failed to land, a chord ended the queue, or focus left the page: the keys go.
    public mutating func drop() {
        surface = nil
        keys = []
        textTaken = false
    }
}
