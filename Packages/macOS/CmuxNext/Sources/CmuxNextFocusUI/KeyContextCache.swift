/// What made a window's cached key facts stale (``KeyContextCache``): the input that changed since the
/// facts were built. `debug.key` and the tests read it; the cache itself only needs "something changed".
public nonisolated enum KeyContextInvalidation: String, CaseIterable, Sendable {
    /// The window's focus machine moved (a new focused pane, tab or field), or its focus settled.
    case focusTransition
    /// The window's first responder changed inside the same focus: a text field, the file explorer
    /// list, the TextBox composer, the code editor's web view.
    case firstResponder
    /// The window shows another top page (Home), or none.
    case topPage
    /// The focused page's ``PageInputReadiness`` reported a list or an editable element taking focus.
    case pageInputReadiness
    /// The focused address bar's suggestion list opened or closed.
    case suggestionList
    /// The focused terminal entered or left copy mode.
    case copyMode
    /// The window's sidebar selection crossed one row (single to multi-selection or back).
    case sidebarSelection
    /// Workspaces as tabs was turned on or off.
    case workspacesAsTabs
    /// The focused markdown page now shows a file it can or cannot save.
    case markdownReadOnly
}

/// The inputs a window's key facts were built from. Every field is an O(1) read (an identity, a flag
/// of an object the last build found), so comparing two stamps costs far less than the facts' own
/// lookups (pane controllers, the responder chain, page services).
public nonisolated protocol KeyContextStamp: Equatable {
    /// The first input that differs from `earlier`; called only when the stamps differ.
    func invalidation(since earlier: Self) -> KeyContextInvalidation
}

/// Each window's key facts behind a generation counter, so a run of chords with no change builds
/// them once (p04-input-053). An entry is reused while the cache's generation is the one it was built
/// at and the window's current stamp equals the stored one; ``invalidate(_:)`` bumps the generation
/// for a change no stamp shows (a focus settle). Chromium keys its DOM-derived caches the same way:
/// `Document::DomTreeVersion()` (third_party/blink/renderer/core/dom/document.h) is a counter every
/// mutation bumps, and a cache built at an older version is rebuilt on its next read.
@MainActor
public final class KeyContextCache<Stamp: KeyContextStamp, Value> {
    private struct Entry {
        weak var owner: AnyObject?
        var generation: UInt64
        var stamp: Stamp
        var value: Value
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// Bumped by every ``invalidate(_:)``: an entry built at an older generation is rebuilt.
    public private(set) var generation: UInt64 = 0
    /// How many times a value was built (the bench and the tests read it).
    public private(set) var builds = 0
    /// The last reason an entry was found stale (nil until one was).
    public private(set) var lastInvalidation: KeyContextInvalidation?

    public init() {}

    nonisolated deinit {}

    /// Every window's entry is stale: `source` changed in a way no stamp shows.
    public func invalidate(_ source: KeyContextInvalidation) {
        generation &+= 1
        lastInvalidation = source
    }

    /// `owner`'s value: the cached one while it is current, else `build`'s (stored).
    ///
    /// - Parameters:
    ///   - owner: The window the value belongs to; its entry goes when it does.
    ///   - stamp: Reads the current stamp, given the cached value (whose objects it may read).
    ///   - build: Builds the value and the stamp it was built from.
    public func value(for owner: AnyObject, stamp: (Value) -> Stamp, build: () -> (value: Value, stamp: Stamp)) -> Value {
        let key = ObjectIdentifier(owner)
        if let entry = entries[key], entry.owner === owner, entry.generation == generation {
            let current = stamp(entry.value)
            if current == entry.stamp { return entry.value }
            lastInvalidation = current.invalidation(since: entry.stamp)
        }
        let built = build()
        builds += 1
        if entries.values.contains(where: { $0.owner == nil }) { entries = entries.filter { $0.value.owner != nil } }
        entries[key] = Entry(owner: owner, generation: generation, stamp: built.stamp, value: built.value)
        return built.value
    }
}
