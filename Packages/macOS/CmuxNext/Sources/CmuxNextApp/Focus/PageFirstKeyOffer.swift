import AppKit
import CmuxNextActions

/// The one key-down a browser page has first (``KeyRouter/Decision/offerToPage(_:)``) and the
/// cmux action that runs if the page reports it unhandled. Only the latest key is held: a page
/// that handled a key reports nothing, so the next offer replaces it and a stale report never
/// runs. Matched by identity, else by timestamp, key code and modifiers, because Chromium may
/// hand back a copy of the event.
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

    private weak var event: NSEvent?
    private var signature: Signature?
    private var held: Held?

    /// Holds `held` for `event`, replacing any earlier key.
    mutating func offer(_ event: NSEvent, _ held: Held) {
        self.event = event
        signature = Signature(event)
        self.held = held
    }

    /// The held action when `event` is the held key; it is released, so it runs at most once.
    mutating func take(_ event: NSEvent) -> Held? {
        guard let held, self.event === event || (event.timestamp != 0 && signature == Signature(event)) else { return nil }
        clear()
        return held
    }

    mutating func clear() {
        event = nil
        signature = nil
        held = nil
    }
}
