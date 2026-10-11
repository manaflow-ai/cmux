import AppKit

/// One opening owns its original key events until its field and native responder are ready.
/// The hold always ends: by the field's readiness, by the opening ending (the page left, focus
/// moved elsewhere), or by the hold limit. A hold that ends without readiness gives its keys back,
/// in typing order, to whatever has focus then; no key is ever dropped (nightly 2026-10-11: a
/// page whose readiness never came held every key of its window).
@MainActor
final class NewTabInputBuffer {
    let token = UUID().uuidString
    let began: ContinuousClock.Instant
    private var events: [NSEvent] = []
    private var acknowledged = false
    private(set) var replaying = false
    private let focusField: () -> Bool
    private let deliver: (NSEvent) -> Void

    init(began: ContinuousClock.Instant, focusField: @escaping () -> Bool, deliver: @escaping (NSEvent) -> Void) {
        self.began = began
        self.focusField = focusField
        self.deliver = deliver
    }

    var hasPending: Bool { !events.isEmpty }

    func capture(_ event: NSEvent) -> Bool {
        guard !replaying else { return false }
        events.append(event)
        return true
    }

    func acknowledge(_ token: String) {
        if token == self.token { acknowledged = true }
    }

    /// Called by the acknowledgement and content/focus events; no elapsed-time readiness guess.
    func drain() -> Bool {
        guard acknowledged, !replaying, focusField() else { return false }
        release()
        return true
    }

    /// Gives every held key, in typing order, to the normal dispatch (whatever has focus now).
    func release() {
        guard !replaying else { return }
        replaying = true
        let pending = events
        events.removeAll()
        for event in pending { deliver(event) }
        replaying = false
    }
}
