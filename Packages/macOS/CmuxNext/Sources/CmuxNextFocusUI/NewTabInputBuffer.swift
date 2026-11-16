public import AppKit
import CmuxNextActions

/// One opening owns its original key events until its field and native responder are ready.
/// The hold always ends: by the field's readiness, by the opening ending (the page left, focus
/// moved elsewhere), or by the hold limit (nightly 2026-10-11: a page whose readiness never came
/// held every key of its window). A hold that ends without readiness gives its keys on, in typing
/// order, to what has the keyboard then. Three kinds of key do not go on: the keys of a page that
/// closed before it existed (`discard`), the keys of a hold that a newer opening replaced (they
/// wait for the newer page, `takeKeys`), and the keys that would go to the view that had the
/// keyboard when the hold opened (``NewTabHoldKeyboard``).
@MainActor
public final class NewTabInputBuffer {
    public let token = UUID().uuidString
    public let began: ContinuousClock.Instant
    private var events: [NSEvent] = []
    private var acknowledged = false
    public private(set) var replaying = false
    private let focusField: () -> Bool
    private let deliver: (NSEvent) -> Void

    /// `held`: the keys of the hold this one replaced. They go first.
    public init(began: ContinuousClock.Instant, held: [NSEvent] = [], focusField: @escaping () -> Bool, deliver: @escaping (NSEvent) -> Void) {
        self.began = began
        self.events = held
        self.focusField = focusField
        self.deliver = deliver
    }

    public var hasPending: Bool { !events.isEmpty }
    public var count: Int { events.count }

    public func capture(_ event: NSEvent) -> Bool {
        guard !replaying else { return false }
        events.append(event)
        return true
    }

    public func acknowledge(_ token: String) {
        if token == self.token { acknowledged = true }
    }

    /// Called by the acknowledgement and content/focus events; no elapsed-time readiness guess.
    public func drain() -> Bool {
        guard acknowledged, !replaying, focusField() else { return false }
        release()
        return true
    }

    /// Drops every held key: the page they were typed into closed before it existed ("Close
    /// before create"), so they go with it, never to another tab.
    public func discard() { events.removeAll() }

    /// A newer opening in the same window replaces this hold: its keys leave it and wait for the newer page.
    public func takeKeys() -> [NSEvent] {
        guard !replaying else { return [] }
        defer { events.removeAll() }
        return events
    }

    /// Gives every held key, in typing order, to the hold's owner, which sends it on. They are the person's own
    /// keys, so they go on with no `ActionRunScope`, whatever run ends the hold (a CLI's opening, a menu pick, a create
    /// task); other state of that run (its daemon command scope, a registry capture) still applies.
    public func release() {
        guard !replaying else { return }
        replaying = true
        let pending = events
        events.removeAll()
        ActionRunScope.carrying(nil) {
            for event in pending { deliver(event) }
        }
        replaying = false
    }
}
