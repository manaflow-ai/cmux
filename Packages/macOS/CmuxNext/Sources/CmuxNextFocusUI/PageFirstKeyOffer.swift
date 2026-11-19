public import AppKit

/// The key-downs browser pages have first (the key router's `offerToPage` decision), each with the cmux action
/// (`Held`) that runs if its page reports it unhandled, and the tab it was offered to.
///
/// A bounded queue in offer order: a second key offered before the page reported the first (fast typing, a key
/// repeat, Cmd-F then Cmd-G) no longer replaces it. Chromium reports keys in the order it got them, so a report
/// releases its key and every older one (a page that handled a key reports nothing for it). A report from another
/// tab than the one the key was offered to runs nothing. Matched by identity, else by timestamp, key code and
/// modifiers, because Chromium may hand back a copy of the event.
public struct PageFirstKeyOffer<Held> {
    /// A key-down as a report matches it (timestamp, key code, modifiers): a value to hold across a wait, where the
    /// event itself (not `Sendable`) cannot go.
    public struct Signature: Equatable, Sendable {
        var timestamp: TimeInterval
        var keyCode: UInt16
        var modifiers: UInt

        public init(_ event: NSEvent) {
            timestamp = event.timestamp
            keyCode = event.keyCode
            modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        }
    }

    private struct Entry {
        weak var event: NSEvent?
        var signature: Signature
        var held: Held
        /// The browser tab the key went to (`ObjectIdentifier` of the tab): only its report runs the action.
        var tab: ObjectIdentifier

        func matches(_ other: NSEvent) -> Bool {
            event === other || (other.timestamp != 0 && signature == Signature(other))
        }
    }

    /// Keys held at most: older ones are dropped first (their pages never reported them).
    public static var limit: Int { 16 }
    private var entries: [Entry] = []

    public init() {}

    /// Keys held now (tests).
    public var count: Int { entries.count }

    /// Holds `held` for `event`, offered to `tab`, after the keys held already.
    public mutating func offer(_ event: NSEvent, _ held: Held, tab: ObjectIdentifier) {
        entries.append(Entry(event: event, signature: Signature(event), held: held, tab: tab))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// The held action when `event` is a held key reported by `tab`, the tab it was offered to. The key and every
    /// older one are released, so each runs at most once.
    public mutating func take(_ event: NSEvent, from tab: ObjectIdentifier) -> Held? {
        guard let index = entries.firstIndex(where: { $0.matches(event) }) else { return nil }
        let entry = entries[index]
        entries.removeFirst(index + 1)
        return entry.tab == tab ? entry.held : nil
    }

    /// Whether the key `signature` names is still held: its page has not reported it unhandled (a page that keeps a key
    /// reports nothing).
    public func holds(_ signature: Signature) -> Bool { entries.contains { $0.signature == signature } }

    public mutating func clear() {
        entries.removeAll()
    }
}
