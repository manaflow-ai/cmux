import AppKit
import CmuxNextActions

/// The key-downs browser pages have first (``KeyRouter/Decision/offerToPage(_:)``), each with the cmux action that
/// runs if its page reports it unhandled, and the tab it was offered to.
///
/// A bounded queue in offer order: a second key offered before the page reported the first (fast typing, a key
/// repeat, Cmd-F then Cmd-G) no longer replaces it. Chromium reports keys in the order it got them, so a report
/// releases its key and every older one (a page that handled a key reports nothing for it). A report from another
/// tab than the one the key was offered to runs nothing. Matched by identity, else by timestamp, key code and
/// modifiers, because Chromium may hand back a copy of the event.
struct PageFirstKeyOffer {
    struct Held {
        var candidate: KeyRouter.Candidate
        var context: KeyContext
        var window: String
        /// The browser tab the key went to (`ObjectIdentifier` of the tab): only its report runs the action.
        var tab: ObjectIdentifier
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

        func matches(_ other: NSEvent) -> Bool {
            event === other || (other.timestamp != 0 && signature == Signature(other))
        }
    }

    /// Keys held at most: older ones are dropped first (their pages never reported them).
    static let limit = 16
    private var entries: [Entry] = []

    /// Keys held now (tests).
    var count: Int { entries.count }

    /// Holds `held` for `event`, after the keys held already.
    mutating func offer(_ event: NSEvent, _ held: Held) {
        entries.append(Entry(event: event, signature: Signature(event), held: held))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// The held action when `event` is a held key reported by `tab`, the tab it was offered to. The key and every
    /// older one are released, so each runs at most once.
    mutating func take(_ event: NSEvent, from tab: ObjectIdentifier) -> Held? {
        guard let index = entries.firstIndex(where: { $0.matches(event) }) else { return nil }
        let held = entries[index].held
        entries.removeFirst(index + 1)
        return held.tab == tab ? held : nil
    }

    mutating func clear() {
        entries.removeAll()
    }
}
