public import CmuxNextInputCore

/// The one test ``InputObserving`` of the CmuxNext test targets: a test delivers each event by hand,
/// and reads which classes the live subscriptions asked for and how many are live.
///
/// It delivers as `InputEventTap.deliverObserve` does: the event becomes ``lastDispatched`` (and
/// ``lastPointer`` for a button, move, drag or scroll), then every live subscription of its class
/// and window hears it, in subscription order. A cancelled or released subscription hears nothing.
///
/// ```swift
/// let tap = FakeInputTap()
/// let events = WindowServerInputEvents(input: tap)
/// tap.deliver(InputEventRecord(type: .keyDown, timestamp: 1))
/// #expect(tap.liveSubscriptions == 1)
/// ```
@MainActor
public final class FakeInputTap: InputObserving {
    private struct Entry {
        let classes: InputEventClasses
        let windowNumber: Int?
        let flag: InputSubscriptionFlag
        let handler: @MainActor (InputEventRecord) -> Void
    }

    private var entries: [Entry] = []
    public private(set) var lastDispatched: InputEventRecord?
    public private(set) var lastPointer: InputEventRecord?

    /// Makes a tap with no subscriptions and no dispatched event.
    public init() {}

    public func observe(_ classes: InputEventClasses, windowNumber: Int?,
                        _ handler: @escaping @MainActor (InputEventRecord) -> Void) -> InputSubscription {
        let flag = InputSubscriptionFlag()
        entries.append(Entry(classes: classes, windowNumber: windowNumber, flag: flag, handler: handler))
        return InputSubscription(flag: flag)
    }

    /// The subscriptions not cancelled or released.
    public var liveSubscriptions: Int { entries.count(where: { !$0.flag.isCancelled }) }

    /// The classes the live subscriptions asked for.
    public var classes: InputEventClasses {
        entries.reduce(into: []) { classes, entry in
            if !entry.flag.isCancelled { classes.formUnion(entry.classes) }
        }
    }

    /// The app dispatched `record`: it becomes the last dispatched (and last pointer) event, and every
    /// live subscription of its class whose window is the record's window or owner window hears it.
    public func deliver(_ record: InputEventRecord) {
        switch record.eventClass {
        case .button, .pointerMove, .drag, .scroll: (lastDispatched, lastPointer) = (record, record)
        case .key, .flags, .gesture: lastDispatched = record
        case .tracking: break
        }
        for entry in entries where !entry.flag.isCancelled && entry.classes.contains(record.eventClass) {
            if let window = entry.windowNumber, window != record.windowNumber, window != record.ownerWindowNumber { continue }
            entry.handler(record)
        }
    }
}
