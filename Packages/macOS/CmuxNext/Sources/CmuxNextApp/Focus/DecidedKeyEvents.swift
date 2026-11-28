import AppKit

/// The key-downs the dispatcher decided, so the window hook, Chromium's
/// pre-key hook and the menu gate run nothing for them. Matched by identity
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

    private let events = NSHashTable<NSEvent>.weakObjects()
    private var recent: [Signature] = []
    private static let recentLimit = 16

    func add(_ event: NSEvent) {
        events.add(event)
        guard event.timestamp != 0 else { return }
        recent.append(Signature(event))
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
    }

    func contains(_ event: NSEvent) -> Bool {
        if events.contains(event) { return true }
        return event.timestamp != 0 && recent.contains(Signature(event))
    }
}
