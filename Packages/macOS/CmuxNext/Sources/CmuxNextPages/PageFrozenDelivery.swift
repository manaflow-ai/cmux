import CmuxNextSettings

/// What a ``PageRouter`` holds for a page that the hibernation froze (PageWebView+ChromiumCost.swift):
/// a frozen renderer runs no script, so its subscriptions' events wait here instead of queueing in
/// the renderer, and a push does not thaw the page (that kept every page the host feeds awake).
///
/// Each stream's ``PageStreamFreezing`` decides: events with one key fold into one, so the page
/// gets one event per key when it thaws (its fresh state, from the subscriptions it already has);
/// an event with no key is the person's input to the page, and
/// ``hold(sub:_:publicationID:freezing:)`` wakes the page for it. Bounded by streams times keys,
/// whatever the hidden time.
@MainActor
final class PageFrozenDelivery {
    /// One held event: `order` is when it came, so events of several streams go in that order.
    struct Held {
        var sub: UInt64
        var order: UInt64
        var data: JSONValue
        var publicationID: UInt64?
    }

    /// The page is frozen now.
    private(set) var isFrozen = false
    /// Thaws the page (the router's owner); set by ``freeze(wake:)``.
    private var wake: (@MainActor () -> Void)?
    private var held: [UInt64: [String: Held]] = [:]
    private var nextOrder: UInt64 = 0

    /// Events held now (tests, `debug.page`).
    var count: Int { held.values.reduce(0) { $0 + $1.count } }

    /// The page froze: events wait from now on. `wake` thaws the page for the person's input to it.
    func freeze(wake: @escaping @MainActor () -> Void) {
        isFrozen = true
        self.wake = wake
    }

    /// The page thawed: the held events, oldest first, to send now.
    func thaw() -> [Held] {
        isFrozen = false
        wake = nil
        let events = held.values.flatMap(\.values).sorted { $0.order < $1.order }
        held.removeAll()
        return events
    }

    /// Thaws the page through its owner (a host call into it), when it is frozen.
    func wakePage() {
        guard isFrozen else { return }
        wake?()
    }

    /// While the page is frozen: folds `data` into the event held for its key and returns true, or,
    /// for the person's input to the page, thaws the page and returns false (send it now, after the
    /// held ones). A folded event goes at the place of its newest part.
    func hold(sub: UInt64, _ data: JSONValue, publicationID: UInt64?, freezing: PageStreamFreezing) -> Bool {
        guard isFrozen else { return false }
        guard let key = freezing.key(data) else {
            wakePage()
            return false
        }
        nextOrder &+= 1
        let folded = freezing.fold(held[sub]?[key]?.data, data)
        held[sub, default: [:]][key] = Held(sub: sub, order: nextOrder, data: folded, publicationID: publicationID)
        return true
    }

    /// The subscription ended: its held events go with it.
    func drop(sub: UInt64) {
        held.removeValue(forKey: sub)
    }

    /// The page's document ended (close, reload): nothing is held or frozen for the next one.
    func reset() {
        isFrozen = false
        wake = nil
        held.removeAll()
    }
}
