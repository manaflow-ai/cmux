public import AppKit

/// One New Tab opening's keys, from the shortcut until its field and native responder are ready. The keys wait in the
/// window's ``WindowInputQueue``, stamped with this opening's page (``WindowInputQueue/Target/newTabPage(_:)``), and go
/// only to that field, in typed order, at its readiness (``drain()``). An opening that ends without readiness (its page
/// left or closed, its creation failed, the person moved on) drops them with a reason (``drop(_:)``); they are never
/// given to whatever has focus, and no timer ends the hold (principled audit, lagFirstKey). The field is ready when
/// the page acknowledged this opening's token, or when the page's document has its field focused already (`fieldReady`:
/// an adopted spare, whose readiness message for this token may never come).
@MainActor
public final class NewTabInputBuffer {
    public let token = UUID().uuidString
    public let began: ContinuousClock.Instant
    /// The target its keys are stamped with in the window's queue.
    public let target: WindowInputQueue.Target
    private let queue: WindowInputQueue
    private var acknowledged = false
    public private(set) var replaying = false
    private let fieldReady: () -> Bool
    private let focusField: () -> Bool
    private let deliver: (NSEvent) -> Void

    /// - Parameters:
    ///   - fieldReady: Whether the page's field is ready without an acknowledgement (its document focused it).
    ///   - focusField: Gives the field the keyboard; false when it cannot yet.
    ///   - deliver: Sends one held key on.
    public init(began: ContinuousClock.Instant, queue: WindowInputQueue, fieldReady: @escaping () -> Bool = { false },
                focusField: @escaping () -> Bool, deliver: @escaping (NSEvent) -> Void) {
        self.began = began
        self.queue = queue
        self.fieldReady = fieldReady
        target = .newTabPage(token)
        self.focusField = focusField
        self.deliver = deliver
    }

    public var hasPending: Bool { queue.waiting(for: target) > 0 }
    public var count: Int { queue.waiting(for: target) }

    public func capture(_ event: NSEvent) -> Bool {
        guard !replaying else { return false }
        queue.capture(event, for: target)
        return true
    }

    public func acknowledge(_ token: String) {
        if token == self.token { acknowledged = true }
    }

    /// At the field's readiness (its acknowledgement, or its document focused it, and the field took the keyboard): the
    /// keys go to it, in order. Called by the acknowledgement, content/focus events and each key; no elapsed-time guess.
    public func drain() -> Bool {
        guard !replaying, acknowledged || fieldReady(), focusField() else { return false }
        replaying = true
        queue.drain(target, takesKeys: { true }, deliver: deliver)
        replaying = false
        return true
    }

    /// Drops every held key (`reason` says why): the field they were typed for will not take them.
    public func drop(_ reason: WindowInputQueue.DropReason) { queue.drop(target, reason) }

    /// The keys still waiting are `next`'s: a held key that ran (a Cmd-T) opened `next`, and they were typed after it.
    public func handOver(to next: NewTabInputBuffer) { queue.retarget(target, to: next.target) }
}
