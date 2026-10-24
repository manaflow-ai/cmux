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

    /// Keys held at most per tab; a tab's oldest is dropped first. A memory bound only: a key the page handled is
    /// released by the tab's next report, so keys pile up only in a tab that handles every page-first key it gets (a
    /// page that takes Cmd-F, Copy and Paste itself). The bound drops a key that would still be reported only when that
    /// tab's renderer is 64 page-first keys behind: at the fastest key repeat macOS offers (15 ms, `KeyRepeat` 1) that
    /// is a key held for about one second against a renderer that answered none of it.
    static let limit = 64
    private var entries: [Entry] = []

    /// Keys held now (tests).
    var count: Int { entries.count }

    /// Holds `held` for `event`, after the keys held already.
    mutating func offer(_ event: NSEvent, _ held: Held) {
        entries.append(Entry(event: event, signature: Signature(event), held: held))
        if entries.count(where: { $0.held.tab == held.tab }) > Self.limit,
           let oldest = entries.firstIndex(where: { $0.held.tab == held.tab }) {
            entries.remove(at: oldest)
        }
    }

    /// The held action when `event` is a held key reported by `tab`, the tab it was offered to. The key and the
    /// reporting tab's older keys are released, so each runs at most once; other tabs' keys stay held.
    mutating func take(_ event: NSEvent, from tab: ObjectIdentifier) -> Held? {
        guard let index = entries.firstIndex(where: { $0.matches(event) }) else { return nil }
        let held = entries[index].held
        var kept = entries[..<index].filter { $0.held.tab != tab }
        kept.append(contentsOf: entries[(index + 1)...])
        entries = kept
        return held.tab == tab ? held : nil
    }

    mutating func clear() {
        entries.removeAll()
    }
}
