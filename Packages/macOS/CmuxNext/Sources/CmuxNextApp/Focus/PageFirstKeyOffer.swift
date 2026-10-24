import AppKit
import CmuxNextActions

/// The key-downs browser pages have first (``KeyRouter/Decision/offerToPage(_:)``), each with the cmux action that
/// runs if its page reports it unhandled, and the tab it was offered to.
///
/// One queue per tab, in offer order: a second key offered before the page reported the first (fast typing, a key
/// repeat, Cmd-F then Cmd-G) no longer replaces it. A page that handled a key reports nothing for it, so a report
/// releases its key and the older keys of the reporting tab only: Chromium reports keys in order within one renderer,
/// never across tabs in other renderer processes (Cmd-F to a busy tab A, then Cmd-G to tab B: B may report first, and
/// A's Find still runs when A reports). A report from another tab than the one the key was offered to runs nothing.
/// Matched by identity, else by timestamp, key code and modifiers, because Chromium may hand back a copy of the event.
struct PageFirstKeyOffer {
    struct Held {
        var candidate: KeyRouter.Candidate
        var context: KeyContext
        var window: String
    }

    private struct Signature: Equatable {
        var timestamp: TimeInterval
        var keyCode: UInt16
        var modifiers: UInt

        init(_ event: NSEvent) {
            timestamp = event.timestamp
            keyCode = event.keyCode
            modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        }
    }

    private struct Entry {
        weak var event: NSEvent?
        var signature: Signature
        var held: Held
        /// Offer order across every tab (a report releases the reporting tab's keys offered before its key).
        var order: UInt64

        func matches(_ other: NSEvent) -> Bool {
            event === other || (other.timestamp != 0 && signature == Signature(other))
        }
    }

    /// One tab's held keys, oldest first. The tab is held weakly: a closed tab's queue goes at the next offer, and a
    /// new tab that reuses a released tab's `ObjectIdentifier` never inherits its keys.
    private struct TabQueue {
        weak var tab: AnyObject?
        var entries: [Entry] = []
    }

    /// Keys held at most per tab; a tab's oldest is dropped first. A memory bound only: a key the page handled is
    /// released by the tab's next report, so keys pile up only in a tab that handles every page-first key it gets (a
    /// page that takes Cmd-F, Copy and Paste itself). The bound drops a key that would still be reported only when that
    /// tab's renderer is 64 page-first keys behind: at the fastest key repeat macOS offers (15 ms, `KeyRepeat` 1) that
    /// is a key held for about one second against a renderer that answered none of it.
    static let limit = 64
    /// Held keys by tab: an offer and a report touch their own tab's queue (and, for a report of a key held for
    /// another tab, that tab's), never every held key.
    private var queues: [ObjectIdentifier: TabQueue] = [:]
    private var nextOrder: UInt64 = 0

    /// Keys held now (tests).
    var count: Int { queues.values.reduce(0) { $0 + $1.entries.count } }

    /// Holds `held` for `event`, offered to the page of `tab` (only its report runs the action), after the keys held
    /// already. The queues of closed tabs go first.
    mutating func offer(_ event: NSEvent, _ held: Held, to tab: AnyObject) {
        if queues.values.contains(where: { $0.tab == nil }) { queues = queues.filter { $0.value.tab != nil } }
        nextOrder &+= 1
        let key = ObjectIdentifier(tab)
        var queue = queues.removeValue(forKey: key) ?? TabQueue(tab: tab)
        queue.entries.append(Entry(event: event, signature: Signature(event), held: held, order: nextOrder))
        if queue.entries.count > Self.limit { queue.entries.removeFirst(queue.entries.count - Self.limit) }
        queues[key] = queue
    }

    /// The held action when `event` is a held key reported by `tab`, the tab it was offered to. The key and the
    /// reporting tab's older keys are released, so each runs at most once; other tabs' keys stay held. A key held for
    /// another tab (focus moved before Chromium reported) is released too, with the reporting tab's keys offered before
    /// it, and runs nothing.
    mutating func take(_ event: NSEvent, from tab: AnyObject) -> Held? {
        let key = ObjectIdentifier(tab)
        if var own = queues.removeValue(forKey: key), own.tab === tab {
            if let index = own.entries.firstIndex(where: { $0.matches(event) }) {
                let held = own.entries[index].held
                own.entries.removeFirst(index + 1)
                if !own.entries.isEmpty { queues[key] = own }
                return held
            }
            queues[key] = own
        }
        guard let found = queues.lazy.compactMap({ owner, queue in
            queue.entries.firstIndex(where: { $0.matches(event) }).map { (owner: owner, index: $0) }
        }).first, var queue = queues.removeValue(forKey: found.owner) else { return nil }
        let order = queue.entries.remove(at: found.index).order
        if !queue.entries.isEmpty { queues[found.owner] = queue }
        if var own = queues.removeValue(forKey: key) {
            own.entries.removeAll { $0.order < order }
            if !own.entries.isEmpty { queues[key] = own }
        }
        return nil
    }
}
