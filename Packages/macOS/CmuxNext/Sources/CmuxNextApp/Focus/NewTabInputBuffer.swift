import AppKit

/// One opening owns its original key events until its field and native responder are ready.
@MainActor
final class NewTabInputBuffer {
    let token = UUID().uuidString
    private var events: [NSEvent] = []
    private var acknowledged = false
    private(set) var replaying = false
    private let focusField: () -> Bool
    private let deliver: (NSEvent) -> Void

    init(focusField: @escaping () -> Bool, deliver: @escaping (NSEvent) -> Void) {
        self.focusField = focusField
        self.deliver = deliver
    }

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
        replaying = true
        let pending = events
        events.removeAll()
        for event in pending { deliver(event) }
        replaying = false
        return true
    }
}
