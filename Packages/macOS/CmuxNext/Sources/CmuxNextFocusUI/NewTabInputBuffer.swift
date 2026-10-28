public import AppKit

/// One opening owns its original key events until its field and native responder are ready.
/// The field is ready when the page acknowledged this opening's token, or when the page's document
/// has its field focused already (``init(began:fieldReady:focusField:deliver:)``'s `fieldReady`: an adopted
/// spare, whose readiness message for this token may never come).
/// The hold always ends: by the field's readiness, by the opening ending (the page left, focus
/// moved elsewhere), or by the hold limit. A hold that ends without readiness gives its keys back,
/// in typing order, to whatever has focus then; no key is ever dropped (nightly 2026-10-11: a
/// page whose readiness never came held every key of its window).
@MainActor
public final class NewTabInputBuffer {
    public let token = UUID().uuidString
    public let began: ContinuousClock.Instant
    private var events: [NSEvent] = []
    private var acknowledged = false
    public private(set) var replaying = false
    private let fieldReady: () -> Bool
    private let focusField: () -> Bool
    private let deliver: (NSEvent) -> Void

    /// - Parameters:
    ///   - fieldReady: Whether the page's field is ready without an acknowledgement (its document focused it).
    ///   - focusField: Gives the field the keyboard; false when it cannot yet.
    ///   - deliver: Sends one held key on.
    public init(began: ContinuousClock.Instant, fieldReady: @escaping () -> Bool = { false }, focusField: @escaping () -> Bool,
                deliver: @escaping (NSEvent) -> Void) {
        self.began = began
        self.fieldReady = fieldReady
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

    /// Called by the acknowledgement, content/focus events and each key; no elapsed-time readiness guess.
    public func drain() -> Bool {
        guard !replaying, acknowledged || fieldReady(), focusField() else { return false }
        release()
        return true
    }

    /// Drops every held key: the page they were typed into closed before it existed ("Close
    /// before create"), so they go with it, never to another tab.
    public func discard() { events.removeAll() }

    /// Gives every held key, in typing order, to the normal dispatch (whatever has focus now).
    public func release() {
        guard !replaying else { return }
        replaying = true
        let pending = events
        events.removeAll()
        for event in pending { deliver(event) }
        replaying = false
    }
}
