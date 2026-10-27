import CmuxNextCompat

/// A person's input as ``InputEventRecord`` values, for core and service packages that must not see
/// AppKit (Wakeups, ChromiumWarmup). The app's one input tap (`InputEventTap` in CmuxNextInput) is the
/// implementation; the composition root passes it to each consumer's init.
///
/// Observers run on the main thread inside `NSApplication.sendEvent`, before the key router and any
/// responder, in subscription order. They see the same events an AppKit local monitor sees.
///
/// ```swift
/// subscription = input.observe([.key, .button]) { [weak self] record in
///     if record.type.isKeyOrClick { self?.noteInput(at: record.timestamp) }
/// }
/// ```
@MainActor
public protocol InputObserving: AnyObject {
    /// Calls `handler` with each event of `classes` before it is dispatched, until the returned
    /// subscription is cancelled or released.
    ///
    /// - Parameters:
    ///   - classes: The event classes to receive.
    ///   - windowNumber: Only events whose window or owner window has this number; nil for every window.
    ///   - handler: Main-thread work for one event. It must not allocate or block: it runs for every
    ///     matching event.
    /// - Returns: The subscription; keep it in a stored property.
    func observe(_ classes: InputEventClasses, windowNumber: Int?,
                 _ handler: @escaping @MainActor (InputEventRecord) -> Void) -> InputSubscription

    /// The last event the app dispatched, nil before the first. Every key, flags-changed and pointer
    /// event replaces it, so outside dispatch read the current modifiers from it instead of
    /// `NSEvent.modifierFlags`.
    var lastDispatched: InputEventRecord? { get }

    /// The last pointer event (button, move, drag or scroll) the app dispatched, nil before the first:
    /// read the pointer's place from it outside dispatch instead of `NSEvent.mouseLocation`. Its
    /// modifiers are that event's, not the current ones (a Shift press does not replace it).
    var lastPointer: InputEventRecord? { get }
}

extension InputObserving {
    /// ``observe(_:windowNumber:_:)`` for every window.
    public func observe(_ classes: InputEventClasses,
                        _ handler: @escaping @MainActor (InputEventRecord) -> Void) -> InputSubscription {
        observe(classes, windowNumber: nil, handler)
    }
}

/// One subscription to the input tap. Calling ``cancel()`` or releasing it, on any thread, stops the
/// calls: it sets a flag the tap reads before each call (one relaxed load) and the tap drops the entry
/// on the main thread later, so no lock and no main-thread hop is needed.
public final class InputSubscription: Sendable {
    /// The flag the tap's entry shares.
    public let flag: InputSubscriptionFlag

    /// A subscription whose entry reads `flag`.
    public init(flag: InputSubscriptionFlag) { self.flag = flag }

    /// Stops the calls now (also happens when the subscription is released).
    public func cancel() { flag.cancel() }

    /// Whether the calls stopped.
    public var isCancelled: Bool { flag.isCancelled }

    deinit { flag.cancel() }
}

/// The cancelled bit one subscription and its tap entry share.
public final class InputSubscriptionFlag: Sendable {
    private let cancelled = Atomic<Bool>(false)

    public init() {}

    /// Whether the subscription was cancelled or released.
    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    /// Marks the subscription cancelled (any thread; a second call does nothing).
    public func cancel() { cancelled.store(true, ordering: .relaxed) }
}
