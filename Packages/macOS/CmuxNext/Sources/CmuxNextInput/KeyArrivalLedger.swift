public import AppKit
public import CmuxNextInputCore

/// A view that knows when it was made: a late key's log says how new the terminal that took it was
/// (`TerminalSurfaceView`).
public protocol InputCreationStamped: AnyObject {
    /// When the view was made (`CLOCK_UPTIME_RAW` nanoseconds).
    var createdNanos: UInt64 { get }
}

/// When each key-down first reached the app's main thread, which cmux path held it, and the keys whose dispatch
/// started late (first-seconds-evidence.md step 1).
///
/// ``InputLatencyDispatch/willDispatch(_:synthetic:keyWindow:)`` calls ``arrived(_:at:)`` for every key-down before
/// it opens the key's slot. A key that a cmux path holds (``held(_:by:at:)``) and sends again later through
/// `NSApp.sendEvent` (a creation hold's replay) reaches `sendEvent` twice with the same `NSEvent` (same OS timestamp
/// and key code); the second call gets back the first arrival. So the slot of the dispatch that runs the key has
/// `arrivedMain` = the first time the main thread had it, and `dispatchStart` = that dispatch:
/// `generated -> arrivedMain` is the time the main thread did not pull the event, `arrivedMain -> dispatchStart` the
/// time a cmux path held it.
///
/// The per-key path is a scan of a fixed ring of ``capacity`` entries: no allocation, no lock, no `String`. Only a key
/// whose dispatch started more than ``lateNanos`` after its OS time builds a ``LateKey`` row (rare by definition).
@MainActor
public final class KeyArrivalLedger {
    /// The cmux path that held a key before dispatching it.
    public nonisolated enum HoldPath: UInt8, Sendable, CaseIterable, CustomStringConvertible {
        case none
        /// `CreationInputCoordinator`: keys typed after a split or a new terminal tab, until the new terminal has
        /// the keyboard.
        case creation
        /// `NewTabInputCoordinator`: keys typed after Cmd-T, until the New Tab page's field takes them.
        case newTab
        /// The launch picture's undecided keys.
        case launchPicture

        public var description: String {
            switch self {
            case .none: "none"
            case .creation: "creation"
            case .newTab: "newTab"
            case .launchPicture: "launchPicture"
            }
        }
    }

    /// One key-down whose dispatch started more than ``lateNanos`` after its OS event time.
    public nonisolated struct LateKey: Sendable, Equatable {
        public var keyCode: UInt16
        /// The OS event time (`NSEvent.timestamp`), `CLOCK_UPTIME_RAW` nanoseconds.
        public var generatedNanos: UInt64
        /// The first time the main thread had it.
        public var arrivedMainNanos: UInt64
        /// When a cmux path took it to run later, or 0.
        public var heldNanos: UInt64
        /// The dispatch that ran it.
        public var dispatchStartNanos: UInt64
        /// How many times `sendEvent` had it, this one included (2 or more: held and sent again).
        public var deliveries: UInt8
        /// The path that held it, if one did.
        public var heldBy: HoldPath
        /// The latency slot's target (`terminal`, `textView`, ...), or nil when no slot opened.
        public var target: String?
        /// The key window's responder chain at dispatch, first responder first (class names, at most 8).
        public var responderChain: [String]
        /// Nanoseconds from when the first view of that chain that knows its age (a terminal) was made to the dispatch.
        public var responderAgeNanos: UInt64?

        public init(keyCode: UInt16, generatedNanos: UInt64, arrivedMainNanos: UInt64, heldNanos: UInt64 = 0,
                    dispatchStartNanos: UInt64, deliveries: UInt8, heldBy: HoldPath, target: String?,
                    responderChain: [String], responderAgeNanos: UInt64?) {
            self.keyCode = keyCode
            self.generatedNanos = generatedNanos
            self.arrivedMainNanos = arrivedMainNanos
            self.heldNanos = heldNanos
            self.dispatchStartNanos = dispatchStartNanos
            self.deliveries = deliveries
            self.heldBy = heldBy
            self.target = target
            self.responderChain = responderChain
            self.responderAgeNanos = responderAgeNanos
        }
    }

    private struct Entry {
        var timestampBits: UInt64 = 0
        var keyCode: UInt16 = 0
        var arrived: UInt64 = 0
        var held: UInt64 = 0
        var deliveries: UInt8 = 0
        var heldBy: HoldPath = .none
        /// The path and hold ``HeldKeyReplay`` recorded at the key's last replay; nil before its first.
        var recorded: (path: HoldPath, hold: UInt64)?
        /// The app's own synthetic input at its first arrival (`debug.key`), not a person's.
        var synthetic = false
    }

    /// Key-downs remembered at once: more than any hold keeps (a hold of 2 s at 20 keys/s is 40).
    public nonisolated static let capacity = 128
    /// A dispatch that starts later than this after the key's OS time is logged (first-seconds-evidence.md: 100 ms).
    public nonisolated static let lateNanos: UInt64 = 100_000_000
    /// Late keys kept, newest last.
    public nonisolated static let lateCapacity = 256

    private var entries: ContiguousArray<Entry>
    private var next = 0
    private var late: [LateKey] = []
    /// Late keys logged since launch.
    public private(set) var lateTotal: UInt64 = 0

    public init() {
        entries = ContiguousArray(repeating: Entry(), count: Self.capacity)
        late.reserveCapacity(Self.lateCapacity)
    }

    private func index(of event: NSEvent) -> Int? {
        let bits = event.timestamp.bitPattern
        guard bits != 0 else { return nil }
        let code = event.keyCode
        for index in entries.indices where entries[index].timestampBits == bits && entries[index].keyCode == code {
            return index
        }
        return nil
    }

    @discardableResult
    private func insert(_ event: NSEvent, at nanos: UInt64, deliveries: UInt8) -> Int? {
        let bits = event.timestamp.bitPattern
        guard bits != 0 else { return nil }
        let index = next
        entries[index] = Entry(timestampBits: bits, keyCode: event.keyCode, arrived: nanos, deliveries: deliveries)
        next = (next + 1) % entries.count
        return index
    }

    /// `event` reached the main thread's dispatch at `nanos`: returns its first arrival (`nanos` the first time).
    // perf-hot: 0.5us key-dispatch
    public func arrived(_ event: NSEvent, at nanos: UInt64, synthetic: Bool = false) -> UInt64 {
        if let index = index(of: event) {
            if entries[index].deliveries < .max { entries[index].deliveries += 1 }
            return entries[index].arrived
        }
        if let index = insert(event, at: nanos, deliveries: 1) { entries[index].synthetic = synthetic }
        return nanos
    }

    /// Whether `event` was the app's own synthetic input when it first arrived (false when the ledger does not know it).
    public func isSynthetic(_ event: NSEvent) -> Bool {
        index(of: event).map { entries[$0].synthetic } ?? false
    }

    /// A cmux path took `event` at `nanos` to dispatch it later. A key that never passed `sendEvent` (a synthetic key
    /// routed straight to the key router) arrives here: its hold counts from now.
    public func held(_ event: NSEvent, by path: HoldPath, at nanos: UInt64) {
        let known = index(of: event)
        guard let index = known ?? insert(event, at: nanos, deliveries: 0) else { return }
        // A key that never passed `sendEvent` is the app's own (`debug.key` routes straight to the key router).
        if known == nil { entries[index].synthetic = true }
        guard entries[index].heldBy == .none else { return }
        entries[index].heldBy = path
        entries[index].held = nanos
    }

    /// When `event`'s hold began: when a path held it, else its first arrival; nil when the ledger does not know it.
    public func holdStart(of event: NSEvent) -> UInt64? {
        guard let index = index(of: event) else { return nil }
        let entry = entries[index]
        return entry.held > 0 ? entry.held : entry.arrived
    }

    /// Stores `path`'s `hold` as `event`'s record (``HeldKeyReplay``) and returns the record of its previous replay: nil
    /// at its first (or when the ledger no longer knows it). A key its own replay held again is replayed twice.
    public func recordReplay(_ event: NSEvent, path: HoldPath, hold: UInt64) -> (path: HoldPath, hold: UInt64)? {
        guard let index = index(of: event) else { return nil }
        let previous = entries[index].recorded
        entries[index].recorded = (path, hold)
        return previous
    }

    /// The path that held `event` and how many times `sendEvent` had it.
    public func history(of event: NSEvent) -> (heldBy: HoldPath, deliveries: UInt8) {
        guard let index = index(of: event) else { return (.none, 0) }
        return (entries[index].heldBy, entries[index].deliveries)
    }

    /// Logs `event` when its dispatch at `dispatchStart` began more than ``lateNanos`` after its OS time, with its first
    /// arrival `arrived`, the path that held it, `keyWindow`'s responder chain and the age of the view that took it.
    public func logIfLate(_ event: NSEvent, arrived: UInt64, dispatchStart: UInt64, target: InputTarget?, keyWindow: NSWindow?) {
        let generated = InputLatencyTracker.eventNanos(event.timestamp)
        guard generated > 0, dispatchStart > generated, dispatchStart - generated > Self.lateNanos else { return }
        var chain: [String] = []
        var age: UInt64?
        var responder: NSResponder? = keyWindow?.firstResponder
        while let current = responder, chain.count < 8 {
            chain.append(String(describing: type(of: current)))
            if age == nil, let stamped = current as? InputCreationStamped, dispatchStart > stamped.createdNanos {
                age = dispatchStart - stamped.createdNanos
            }
            responder = current.nextResponder
        }
        let entry = index(of: event).map { entries[$0] }
        logLate(LateKey(keyCode: event.keyCode, generatedNanos: generated, arrivedMainNanos: arrived,
                        heldNanos: entry?.held ?? 0, dispatchStartNanos: dispatchStart,
                        deliveries: entry?.deliveries ?? 1, heldBy: entry?.heldBy ?? .none, target: target.map { String(describing: $0) },
                        responderChain: chain, responderAgeNanos: age))
    }

    /// A held key a path ran again outside `NSApplication.sendEvent` (straight to a window or view: the New Tab field's,
    /// the launch picture's): logged when it ran more than ``lateNanos`` after its OS time, with the path that held it.
    /// The key keeps the one slot its first pass opened; this row is its hold.
    public func replayed(_ event: NSEvent, at nanos: UInt64, keyWindow: NSWindow?) {
        let arrived = index(of: event).map { entries[$0].arrived } ?? nanos
        logIfLate(event, arrived: arrived, dispatchStart: nanos, target: nil, keyWindow: keyWindow)
    }

    /// Logs one late key.
    public func logLate(_ key: LateKey) {
        lateTotal &+= 1
        if late.count == Self.lateCapacity { late.removeFirst() }
        late.append(key)
    }

    /// The newest `count` late keys, newest last.
    public func lateKeys(_ count: Int = .max) -> [LateKey] {
        Array(late.suffix(count))
    }
}
