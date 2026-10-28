public import AppKit
public import CmuxNextInputCore
public import CmuxNextWakeups

/// The app's one input tap (plans/cmux-next/chrome-parity/p04-input.md section 3 (A)): every event
/// `NSApplication.sendEvent` dispatches passes it, and owners subscribe here instead of installing
/// AppKit event monitors or closure properties on the application object.
///
/// A subscription names its event classes, its phase (observe, intercept with a declared order, or
/// after dispatch), its window, an optional visibility node and an optional live predicate. A
/// node-scoped subscription runs only while its node is not hidden (p06-scheduler.md B, the
/// InputObserverHub): 40 hidden agent panes and one shown cost one handler call per key-down, not 41. The tap keeps one list per phase and
/// class, so an event costs only the subscribers of its own class, and delivery copies no list and
/// allocates nothing. Chrome routes input the same way: `content/browser/renderer_host/
/// render_widget_host_impl.cc` keeps typed `InputEventObserver` lists and `KeyPressEventCallback`s on
/// the widget the event goes to, not process-wide monitors.
///
/// The application object calls the three delivery points inside one dispatch scope, and the end of
/// the dispatch after it, on every path:
///
/// ```swift
/// tap.sendEventBegan(event)                            // first: the action event's floor (``actionEvent``)
/// tap.dispatching {
///     tap.deliverObserve(event)                        // before the key router
///     if tap.deliverIntercepts(event) == .pass { super.sendEvent(event) }
///     tap.deliverAfterDispatch(event)
/// }
/// tap.deliverDispatchEnd(event, outcome: delivered ? .delivered : .consumed)
/// tap.sendEventEnded()                                 // last, on every path
/// ```
///
/// Subscribing, cancelling or releasing a subscription inside a handler is safe: a list is never
/// changed while it is delivered. A new subscription is added when the event's dispatch scope ends
/// (``dispatching(_:)``), so it never hears the event that made it, in any stage; it hears the next.
///
/// The App's composition root makes one, gives it to the application object, and passes it to every
/// owner by init (core and service owners as ``InputObserving``).
public final class InputEventTap: InputObserving {
    /// The handler one entry calls.
    private enum Handler {
        case event(@MainActor (NSEvent) -> Void)
        case record(@MainActor (InputEventRecord) -> Void)
        case intercept(@MainActor (NSEvent) -> InterceptResult)
        case ended(@MainActor (NSEvent, DispatchOutcome) -> Void)
    }

    /// One subscription in one class list (a subscription to several classes has one entry in each).
    /// Copying one only retains: its window scope is a ``WindowKey`` it holds strongly, so a delivery
    /// loop takes no weak-reference lock per subscriber.
    private struct Entry {
        let flag: InputSubscriptionFlag
        /// The window whose events count; nil for every window.
        let scope: WindowKey?
        /// The thing whose visibility gates the handler (a pane's or a tab's node); nil for always.
        let node: VisibilityNode?
        let order: InterceptOrder
        let active: (@MainActor () -> Bool)?
        let handler: Handler
    }

    /// The stages' lists, one per event class (indexed by `InputEventClass.rawValue`).
    private var observers = Array(repeating: ContiguousArray<Entry>(), count: InputEventClass.allCases.count)
    private var intercepts = Array(repeating: ContiguousArray<Entry>(), count: InputEventClass.allCases.count)
    private var afterDispatch = Array(repeating: ContiguousArray<Entry>(), count: InputEventClass.allCases.count)
    private var dispatchEnds = Array(repeating: ContiguousArray<Entry>(), count: InputEventClass.allCases.count)
    /// Dispatch scopes and deliveries running now (nested ones add one each). Lists change only at 0.
    private var delivering = 0
    /// Subscriptions made during a delivery: added when it ends.
    private var pending: [(entry: Entry, classes: InputEventClasses, stage: Stage)] = []
    /// A cancelled entry was seen: the lists drop dead entries when the delivery ends.
    private var needsCompaction = false
    /// The other-app monitors of ``globalObserve(_:_:)``.
    private var globalMonitors: [GlobalMonitor] = []

    /// The last event the app dispatched, nil before the first. Its modifiers are the current ones:
    /// every key, flags-changed and pointer event replaces it.
    public private(set) var lastDispatched: InputEventRecord?
    /// The last button, move, drag or scroll event the app dispatched, nil before the first: where the
    /// pointer is. Its modifiers are that event's; read the current ones from ``lastDispatched``.
    public private(set) var lastPointer: InputEventRecord?
    /// The app's crash keys: each dispatched event's time is the page's `last_input_uptime`.
    public var crashKeys: CrashKeySlots?
    /// The event the app dispatches now, nil between dispatches: the App's `InputDispatchContext.event`
    /// (`sendEvent` and the key router's own keys). Set once by the composition root; ``actionEvent`` reads it.
    public var dispatchedEvent: @MainActor () -> NSEvent? = { nil }
    /// AppKit's current event, the one a menu or control's tracking loop chose an action with: ``actionEvent``
    /// reads it only through ``actionGate``. The app keeps the default; tests set their own.
    public var currentEvent: @MainActor () -> NSEvent? = { NSApplication.shared.currentEvent } // current-event: target-action
    /// When ``currentEvent`` answers an action (``InputActionEventGate``): `sendEvent` and the menu item action
    /// sends (``menuActionBegan()``) feed it.
    public internal(set) var actionGate = InputActionEventGate()
    /// Owner-set states that per-key work checks in O(1) instead of searching for (``Flags``).
    public private(set) var flags: Flags = []
    /// The holders of each held flag (``holdFlag(_:)``).
    private var flagHolds: [Flags: Int] = [:]

    /// A tap with no subscription.
    public init() {}

    // MARK: Subscribing

    /// Calls `handler` with each event of `classes` in `phase`, until the returned subscription is
    /// cancelled or released. The intercept phase, `.intercept(order:)`, is the other `subscribe`.
    ///
    /// - Parameters:
    ///   - classes: The event classes to receive.
    ///   - phase: Before the key router (`observe`) or after AppKit dispatched the event (`afterDispatch`).
    ///   - window: The windows whose events count.
    ///   - node: The visibility node of the thing that hears: the handler runs only while it is not
    ///     hidden (an unselected tab, a suspended pane, a parked workspace hears nothing). Nil for always.
    ///   - active: Asked before each call; the handler runs only while it returns true. It must be O(1).
    ///   - handler: Main-thread work for one event.
    /// - Returns: The subscription; keep it in a stored property.
    public func subscribe(class classes: InputEventClasses, phase: Phase = .observe, window: WindowScope = .anyWindow,
                          node: VisibilityNode? = nil, while active: (@MainActor () -> Bool)? = nil,
                          handler: @escaping @MainActor (NSEvent) -> Void) -> InputSubscription {
        let stage: Stage = phase == .observe ? .observe : .afterDispatch
        return subscribe(classes, stage: stage, order: .standard, window: window, node: node, active: active, handler: .event(handler))
    }

    /// Calls `handler` with each event of `classes` after the key router and before AppKit dispatches
    /// it, in `phase`'s order among the other intercepts, until the returned subscription is cancelled
    /// or released. A handler that returns ``InterceptResult/consume`` stops the event: later intercepts
    /// and AppKit do not get it; observers already had it and after-dispatch observers still get it.
    ///
    /// - Parameters:
    ///   - classes: The event classes to receive.
    ///   - phase: `.intercept(order:)`: where this intercept runs (``InterceptOrder``'s table).
    ///   - window: The windows whose events count.
    ///   - node: The visibility node of the thing that hears: the intercept runs only while it is not
    ///     hidden, and a hidden one lets the event pass. Nil for always.
    ///   - active: Asked before each call; the handler runs only while it returns true. It must be O(1).
    ///   - handler: Main-thread work for one event; returns whether it consumed the event.
    /// - Returns: The subscription; keep it in a stored property.
    public func subscribe(class classes: InputEventClasses, phase: InterceptPhase, window: WindowScope = .anyWindow,
                          node: VisibilityNode? = nil, while active: (@MainActor () -> Bool)? = nil,
                          handler: @escaping @MainActor (NSEvent) -> InterceptResult) -> InputSubscription {
        switch phase {
        case .intercept(let order):
            subscribe(classes, stage: .intercept, order: order, window: window, node: node, active: active, handler: .intercept(handler))
        }
    }

    /// Calls `handler` with each event of `classes` once its whole dispatch has ended, on every path: AppKit
    /// dispatched it, or the key router, the find pill, the cross-window key guard or an intercept
    /// consumed it (``DispatchOutcome``). It runs outside the event's dispatch scope, until the returned
    /// subscription is cancelled or released.
    ///
    /// - Parameters:
    ///   - classes: The event classes to receive.
    ///   - handler: Main-thread work for one event, with how its dispatch ended. It must be O(1).
    /// - Returns: The subscription; keep it in a stored property.
    public func observeDispatchEnd(_ classes: InputEventClasses,
                                   _ handler: @escaping @MainActor (NSEvent, DispatchOutcome) -> Void) -> InputSubscription {
        subscribe(classes, stage: .dispatchEnd, order: .standard, window: .anyWindow, node: nil, active: nil, handler: .ended(handler))
    }

    /// ``InputObserving``: an observer that gets ``InputEventRecord`` values, for core and service owners.
    public func observe(_ classes: InputEventClasses, windowNumber: Int?,
                        _ handler: @escaping @MainActor (InputEventRecord) -> Void) -> InputSubscription {
        let flag = InputSubscriptionFlag()
        let entry = Entry(flag: flag, scope: windowNumber.map { WindowKey(number: $0) }, node: nil, order: .standard,
                          active: nil, handler: .record(handler))
        add(entry, classes: classes, stage: .observe)
        return InputSubscription(flag: flag)
    }

    /// Calls `handler` with each event of `mask` that goes to another app (AppKit's global monitor, which
    /// sees no event of this app), until the returned subscription is cancelled or released. The tap
    /// removes the monitor at the first event or delivery after the cancel.
    ///
    /// - Parameters:
    ///   - mask: The event types to receive.
    ///   - handler: Main-thread work for one event.
    /// - Returns: The subscription; keep it in a stored property.
    public func globalObserve(_ mask: NSEvent.EventTypeMask,
                              _ handler: @escaping @MainActor (NSEvent) -> Void) -> InputSubscription {
        removeCancelledGlobalMonitors()
        let flag = InputSubscriptionFlag()
        globalMonitors.append(GlobalMonitor(mask, flag: flag, handler: handler))
        return InputSubscription(flag: flag)
    }

    /// The live subscriptions of `stage` that hear `eventClass` (diagnostics, and tests that check an
    /// owner unsubscribes on every end path).
    public func subscriberCount(_ eventClass: InputEventClass, stage: Stage) -> Int {
        let list = switch stage {
        case .observe: observers[Int(eventClass.rawValue)]
        case .intercept: intercepts[Int(eventClass.rawValue)]
        case .afterDispatch: afterDispatch[Int(eventClass.rawValue)]
        case .dispatchEnd: dispatchEnds[Int(eventClass.rawValue)]
        }
        return list.count(where: { !$0.flag.isCancelled }) + pending.count(where: {
            $0.classes.contains(eventClass) && $0.stage == stage && !$0.entry.flag.isCancelled
        })
    }

    /// The other-app monitors installed now (`debug.input` and tests).
    public var globalMonitorCount: Int { globalMonitors.count }

    // MARK: Flags

    /// States that per-key work checks in O(1), each set by its one owner (``setFlag(_:_:)``) or held
    /// by several (``holdFlag(_:)``).
    public struct Flags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// A window shows shortcut hints (its hint owner sets it while they show).
        public static let hintsShowing = Flags(rawValue: 1 << 0)
        /// A find pill's field has the keyboard in some window (each such pill holds it).
        public static let findPillOpen = Flags(rawValue: 1 << 1)
    }

    /// Sets or clears `flag` (called by the flag's owner).
    public func setFlag(_ flag: Flags, _ on: Bool) {
        if on { flags.insert(flag) } else { flags.remove(flag) }
    }

    /// Sets `flag` until every holder released it (``releaseFlag(_:)``): a flag several owners
    /// share, such as one find pill per window, clears when the last lets go.
    public func holdFlag(_ flag: Flags) {
        flagHolds[flag, default: 0] += 1
        flags.insert(flag)
    }

    /// Gives back one ``holdFlag(_:)`` of `flag`; the last clears it. A release with no hold does nothing.
    public func releaseFlag(_ flag: Flags) {
        guard let holds = flagHolds[flag] else { return }
        if holds > 1 { flagHolds[flag] = holds - 1 } else { flagHolds[flag] = nil; flags.remove(flag) }
    }

    // MARK: Delivery

    /// Runs `body`, one event's dispatch through the three stages, as one delivery: a subscription
    /// made in any stage is added when it ends, so none hears the event that made it. The application
    /// object wraps each event's dispatch in it; a nested dispatch joins the outermost.
    // perf-hot: 5us input-tap
    public func dispatching(_ body: () -> Void) {
        delivering += 1
        defer { endDelivery() }
        body()
    }

    /// Records `event` as the last dispatched (and last pointer) event and calls its class's observers.
    /// The application object calls it for every event, before the key router. A tracking-area event
    /// is no input of its own (a move made it), so it replaces neither.
    // perf-hot: 5us input-tap
    public func deliverObserve(_ event: NSEvent) {
        guard let type = InputEventType(event.type) else { return }
        let record = InputEventRecord(event, type: type)
        switch type.eventClass {
        case .button, .pointerMove, .drag, .scroll: (lastDispatched, lastPointer) = (record, record)
        case .key, .flags, .gesture: lastDispatched = record
        case .tracking: break
        }
        if type.eventClass != .tracking { crashKeys?.noteInput(uptimeSeconds: record.timestamp) }
        if !globalMonitors.isEmpty { removeCancelledGlobalMonitors() }
        let index = Int(type.eventClass.rawValue)
        guard !observers[index].isEmpty else { return }
        delivering += 1
        defer { endDelivery() }
        var windows = EventWindows(event, window: record.windowNumber, owner: record.ownerWindowNumber)
        var position = 0
        while position < observers[index].count {
            let entry = observers[index][position]
            position += 1
            guard matches(entry, &windows) else { continue }
            switch entry.handler {
            case .event(let handler): handler(event)
            case .record(let handler): handler(record)
            case .intercept, .ended: break
            }
        }
    }

    /// Calls `event`'s class's intercepts in their order until one consumes it. The application object
    /// calls it after the key router, before `super.sendEvent`, and dispatches the event only on `.pass`.
    // perf-hot: 5us input-tap
    public func deliverIntercepts(_ event: NSEvent) -> InterceptResult {
        guard let type = InputEventType(event.type) else { return .pass }
        let index = Int(type.eventClass.rawValue)
        guard !intercepts[index].isEmpty else { return .pass }
        delivering += 1
        defer { endDelivery() }
        var windows = EventWindows(event)
        var position = 0
        while position < intercepts[index].count {
            let entry = intercepts[index][position]
            position += 1
            guard matches(entry, &windows), case .intercept(let handler) = entry.handler else { continue }
            if handler(event) == .consume { return .consume }
        }
        return .pass
    }

    /// Calls `event`'s class's after-dispatch observers. The application object calls it after AppKit
    /// dispatched the event, or after an intercept consumed it.
    // perf-hot: 5us input-tap
    public func deliverAfterDispatch(_ event: NSEvent) {
        guard let type = InputEventType(event.type) else { return }
        let index = Int(type.eventClass.rawValue)
        guard !afterDispatch[index].isEmpty else { return }
        delivering += 1
        defer { endDelivery() }
        var windows = EventWindows(event)
        var position = 0
        while position < afterDispatch[index].count {
            let entry = afterDispatch[index][position]
            position += 1
            guard matches(entry, &windows), case .event(let handler) = entry.handler else { continue }
            handler(event)
        }
    }

    /// Calls `event`'s class's dispatch-end observers with `outcome`. The application object calls it
    /// once per event, after the event's dispatch scope (``dispatching(_:)``) ended, on every path.
    // perf-hot: 5us input-tap
    public func deliverDispatchEnd(_ event: NSEvent, outcome: DispatchOutcome) {
        guard let type = InputEventType(event.type) else { return }
        let index = Int(type.eventClass.rawValue)
        guard !dispatchEnds[index].isEmpty else { return }
        delivering += 1
        defer { endDelivery() }
        var windows = EventWindows(event)
        var position = 0
        while position < dispatchEnds[index].count {
            let entry = dispatchEnds[index][position]
            position += 1
            guard matches(entry, &windows), case .ended(let handler) = entry.handler else { continue }
            handler(event, outcome)
        }
    }

    // MARK: Internals

    private func subscribe(_ classes: InputEventClasses, stage: Stage, order: InterceptOrder, window: WindowScope,
                           node: VisibilityNode?, active: (@MainActor () -> Bool)?, handler: Handler) -> InputSubscription {
        let flag = InputSubscriptionFlag()
        let scope: WindowKey? = switch window {
        case .anyWindow: nil
        case .window(let window): WindowKey(window: window)
        }
        add(Entry(flag: flag, scope: scope, node: node, order: order, active: active, handler: handler), classes: classes, stage: stage)
        return InputSubscription(flag: flag)
    }

    /// Whether `entry` gets the event whose window numbers `windows` reads, now.
    private func matches(_ entry: Entry, _ windows: inout EventWindows) -> Bool {
        if entry.flag.isCancelled {
            needsCompaction = true
            return false
        }
        if let scope = entry.scope, !windows.belongs(to: scope.number) { return false }
        // O(1): the node keeps its effective state. Occluded still hears: a covered key window types.
        if let node = entry.node, node.effective == .hidden { return false }
        return entry.active?() ?? true
    }

    private func add(_ entry: Entry, classes: InputEventClasses, stage: Stage) {
        guard delivering == 0 else { return pending.append((entry, classes, stage)) }
        for eventClass in InputEventClass.allCases where classes.contains(eventClass) {
            let index = Int(eventClass.rawValue)
            // A list no event of its class reached since a cancel drops its dead entries here.
            switch stage {
            case .observe:
                observers[index].removeAll { $0.flag.isCancelled }
                observers[index].append(entry)
            case .afterDispatch:
                afterDispatch[index].removeAll { $0.flag.isCancelled }
                afterDispatch[index].append(entry)
            case .dispatchEnd:
                dispatchEnds[index].removeAll { $0.flag.isCancelled }
                dispatchEnds[index].append(entry)
            case .intercept:
                intercepts[index].removeAll { $0.flag.isCancelled }
                // Stable: after every intercept of the same or a lower order.
                let position = intercepts[index].firstIndex { $0.order > entry.order } ?? intercepts[index].endIndex
                intercepts[index].insert(entry, at: position)
            }
        }
    }

    private func endDelivery() {
        delivering -= 1
        guard delivering == 0 else { return }
        if needsCompaction {
            needsCompaction = false
            for index in observers.indices {
                observers[index].removeAll { $0.flag.isCancelled }
                intercepts[index].removeAll { $0.flag.isCancelled }
                afterDispatch[index].removeAll { $0.flag.isCancelled }
                dispatchEnds[index].removeAll { $0.flag.isCancelled }
            }
        }
        guard !pending.isEmpty else { return }
        let added = pending
        pending.removeAll()
        for item in added where !item.entry.flag.isCancelled { add(item.entry, classes: item.classes, stage: item.stage) }
    }

    private func removeCancelledGlobalMonitors() {
        guard globalMonitors.contains(where: { $0.flag.isCancelled }) else { return }
        for monitor in globalMonitors where monitor.flag.isCancelled { monitor.remove() }
        globalMonitors.removeAll { $0.flag.isCancelled }
    }
}
