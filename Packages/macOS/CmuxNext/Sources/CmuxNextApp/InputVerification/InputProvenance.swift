import AppKit

/// Whether the last input this app dispatched was a person's or posted by
/// an agent (`SyntheticInput`). SwiftUI applies a control's change after
/// the click's dispatch has ended (and AppKit's tracking loop takes the
/// mouse-up without dispatching it), so a user-only write cannot rely on
/// the event in dispatch alone: it asks whether the click that just
/// happened was posted. An accessibility press has no event; once a
/// second has passed since the last click it reads as the person.
@MainActor
final class InputProvenance {
    static let shared = InputProvenance()
    /// How long a click's provenance applies to the change it causes.
    static let window: TimeInterval = 1

    private var last: (synthetic: Bool, uptime: TimeInterval)?

    /// A dispatched input event, classified by the caller (`CmuxApplication.sendEvent`).
    func note(_ event: NSEvent, synthetic: Bool) {
        guard Self.isGesture(event) else { return }
        last = (synthetic, event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime)
    }

    /// A dispatched event, classified here (tests).
    func note(_ event: NSEvent) {
        note(event, synthetic: !SyntheticInput.isUserInput(event))
    }

    /// The last click or key was posted by an agent, within ``window``.
    func lastInputIsSynthetic(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let last, now - last.uptime <= Self.window else { return false }
        return last.synthetic
    }

    private static func isGesture(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .keyDown, .keyUp: true
        default: false
        }
    }
}
