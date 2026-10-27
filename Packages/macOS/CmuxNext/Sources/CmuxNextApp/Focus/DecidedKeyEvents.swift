import AppKit

/// The key-downs the dispatcher decided, so the window hook, Chromium's
/// pre-key hook and the menu gate run nothing for them (and, as a second set,
/// those whose extension shortcuts it looked up). Matched by identity
/// (weak) and by signature (timestamp, key code, modifiers, characters), so
/// a copy of the same key that Chromium hands back is recognized too. Events
/// with a zero timestamp (AppKit's synthesized key bindings) match by
/// identity only.
final class DecidedKeyEvents {
    private struct Signature: Equatable {
        var timestamp: TimeInterval
        var keyCode: UInt16
        var modifiers: UInt
        var characters: String?

        init(_ event: NSEvent) {
            timestamp = event.timestamp
            keyCode = event.keyCode
            modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            characters = event.charactersIgnoringModifiers
        }
    }

    /// Where the window offered a decided chord as a key equivalent (`debug.key` `key_equivalents`):
    /// the focused surface alone, a field's pane, or AppKit's walk over every view of the window.
    struct Offers: Equatable {
        var focusedSurface = 0
        var fieldPane = 0
        var windowWalks = 0
    }

    var offers = Offers()
    private let events = NSHashTable<NSEvent>.weakObjects()
    private var recent: [Signature] = []
    private static let recentLimit = 16

    func add(_ event: NSEvent) {
        events.add(event)
        guard event.timestamp != 0 else { return }
        recent.append(Signature(event))
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
    }

    func contains(_ event: NSEvent) -> Bool { // perf-hot: 0.5ms key-dispatch (every key-down of the process)
        if events.contains(event) { return true }
        // The timestamp first: a new key matches no recent one, and reads none of its characters (a string per key).
        let timestamp = event.timestamp
        guard timestamp != 0, recent.contains(where: { $0.timestamp == timestamp }) else { return false }
        return recent.contains(Signature(event))
    }
}
