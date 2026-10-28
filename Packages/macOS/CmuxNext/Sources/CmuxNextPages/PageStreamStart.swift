/// Marks the end of a page stream's subscribe call (``PageProvider/subscribe(_:filter:context:onEvent:)``).
/// A provider that follows its state through a `ServiceObservation` gets the current value applied
/// inside the observation's `init`; that value is what the page reads with its own state call, so
/// only applies after ``finish()`` are events.
///
/// ```swift
/// let subscribed = PageStreamStart()
/// let observation = ServiceObservation(.visible, owner: stream, on: work, read: read) { value in
///     if subscribed.isDone { onEvent(value) }
/// }
/// subscribed.finish()
/// return PageSubscription(frozenDelivery: .latest) { observation.cancel() }
/// ```
@MainActor
public final class PageStreamStart {
    /// The subscribe call returned its observation.
    public private(set) var isDone = false

    public init() {}

    /// The subscribe call is done: later applies are events.
    public func finish() {
        isDone = true
    }
}
