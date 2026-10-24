import AppKit

/// The key-downs the dispatcher decided, so the window hook, Chromium's
/// pre-key hook and the menu gate run nothing for them. Matched by identity
/// (weak) and by signature (timestamp, key code, modifiers), so a copy of
/// the same key that Chromium hands back is recognized too. Events with a
/// zero timestamp (AppKit's synthesized key bindings) match by identity only.
///
/// ``contains(_:)`` runs for every key-down of the process (bare typing
/// included), so the signature holds plain values only: no
/// `charactersIgnoringModifiers` (an NSString bridge that can allocate);
/// the timestamp, key code and modifiers already identify one press.
final class DecidedKeyEvents {
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

    private let events = NSHashTable<NSEvent>.weakObjects()
    private var recent: [Signature] = []
    private static let recentLimit = 16

    func add(_ event: NSEvent) {
        events.add(event)
        guard event.timestamp != 0 else { return }
        recent.append(Signature(event))
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
    }

    func contains(_ event: NSEvent) -> Bool { // perf-hot: 0.05ms key-dispatch (every key-down of the process)
        if events.contains(event) { return true }
        guard event.timestamp != 0, !recent.isEmpty else { return false }
        return recent.contains(Signature(event))
    }
}
