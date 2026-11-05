// SPDX-License-Identifier: GPL-3.0-or-later
// The takeover rule follows Petal's ai_chat/takeover.rs and control_gate.rs
// (kiruna-labs/petal @ 7ac436a, Apache-2.0, Copyright Kiruna Labs), ported
// to Swift for the helper that hosts Cua Driver.
import Foundation
import os

/// Where an input event came from, as the takeover tap sees it.
public enum InputProvenance: Sendable, Equatable {
    /// Our own input: it carries `TakeoverMarker`, or this process (where
    /// Cua Driver runs) posted it.
    case agent
    /// Anyone else's deliberate input: a key, a click or a scroll. The
    /// person is driving.
    case person
    /// Anyone else's pointer movement. It moves the person's telepointer
    /// but is not a takeover: a hand resting on the mouse does not stop
    /// the agent.
    case personPointer
    /// Not an event the rule looks at.
    case ignored
}

/// The provenance stamp on input cmux posts itself, as in Petal: the
/// `kCGEventSourceUserData` field set to fixed bytes.
enum TakeoverMarker {
    /// The ASCII bytes "CMUXSYNT".
    static let value: Int64 = 0x434D_5558_5359_4E54
    /// `kCGEventSourceUserData`.
    static let userDataField: UInt32 = 42
    /// `kCGEventSourceUnixProcessID`: the process that posted the event,
    /// 0 for hardware input.
    static let sourcePIDField: UInt32 = 41
}

/// CGEventType raw values the tap listens to.
enum TapEventType {
    static let leftMouseDown: UInt32 = 1
    static let rightMouseDown: UInt32 = 3
    static let mouseMoved: UInt32 = 5
    static let leftMouseDragged: UInt32 = 6
    static let rightMouseDragged: UInt32 = 7
    static let keyDown: UInt32 = 10
    static let flagsChanged: UInt32 = 12
    static let scrollWheel: UInt32 = 22
    static let otherMouseDown: UInt32 = 25
    static let otherMouseDragged: UInt32 = 27

    static let deliberate: Set<UInt32> = [
        leftMouseDown, rightMouseDown, otherMouseDown, keyDown, scrollWheel,
        leftMouseDragged, rightMouseDragged, otherMouseDragged,
    ]
    static let pointer: Set<UInt32> = [mouseMoved]

    /// Every type above, as a CGEventMask.
    static var mask: UInt64 {
        (deliberate.union(pointer)).reduce(0) { $0 | (1 << UInt64($1)) }
    }
}

/// Classify one event. Pure, so the rule is testable without a window
/// server. An event with our marker or our pid is ours whatever its type;
/// anything else that is deliberate input is the person's. A wrong guess
/// errs toward the person: it pauses the agent rather than letting it act
/// over someone.
public func classifyInput(type: UInt32, userData: Int64, sourcePID: Int64, ownPID: Int64) -> InputProvenance {
    if userData == TakeoverMarker.value || (sourcePID != 0 && sourcePID == ownPID) { return .agent }
    if TapEventType.deliberate.contains(type) { return .person }
    if TapEventType.pointer.contains(type) { return .personPointer }
    return .ignored
}

/// When the agent may act again after the person took over.
///
/// - The person takes over on any deliberate input of theirs (a key, a
///   click, a scroll, a drag). Moving the pointer alone does not.
/// - The agent resumes once the person has been quiet for `quiet`.
/// - An acting call that arrives while the person is in control waits for
///   that quiet, up to `hold`; if the person is still going, it is refused
///   with `person_in_control` and does not run. Observing calls never wait.
/// - With no working detector (no tap, or our marker did not come back)
///   the gate is open, and `cua_status`-style reports say so: Computer Use
///   works as before rather than failing on a missing grant.
public struct TakeoverRule: Sendable, Equatable {
    public var quiet: Duration
    public var hold: Duration

    public init(quiet: Duration = .milliseconds(1500), hold: Duration = .seconds(10)) {
        self.quiet = quiet
        self.hold = hold
    }
}

/// Who has the machine right now.
public enum ControlHolder: Sendable, Equatable {
    case agent
    /// The person, until `resumesAt` (uptime nanoseconds) unless they act again.
    case person(resumesAt: UInt64)
    /// The detector is not running or could not prove provenance.
    case unwatched
}

/// The person's latest pointer position, for telepointers: global display
/// points, top-left origin, and when it was seen (uptime nanoseconds).
public struct PointerSample: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var atNanos: UInt64

    public init(x: Double, y: Double, atNanos: UInt64) {
        self.x = x
        self.y = y
        self.atNanos = atNanos
    }
}

/// Counters for measurement, read with `TakeoverGate.snapshot()`.
public struct TakeoverStats: Sendable, Equatable {
    public var agentEvents: UInt64 = 0
    public var personEvents: UInt64 = 0
    /// Transitions from the agent to the person.
    public var takeovers: UInt64 = 0
    /// Acting calls that waited for the person to stop.
    public var held: UInt64 = 0
    /// Acting calls refused with `person_in_control`.
    public var refused: UInt64 = 0
}

/// A call refused because the person is driving.
public struct TakeoverRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    public static let code = "person_in_control"
    public let tool: String

    public init(tool: String) { self.tool = tool }

    public var description: String {
        "\(Self.code): the person is using this Mac. `\(tool)` did not run. "
            + "Wait until they stop, then try again."
    }
}

/// The takeover state at the execution boundary. The tap feeds it events;
/// `admit` runs after the consent gate, right before the driver acts.
public final class TakeoverGate: Sendable {
    public typealias Clock = @Sendable () -> UInt64
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    private struct State {
        var healthy = false
        var lastPerson: UInt64?
        var pointer: PointerSample?
        var stats = TakeoverStats()
    }

    public let rule: TakeoverRule
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let now: Clock
    private let sleep: Sleeper
    private let starter: (@Sendable () -> Void)?

    /// `starter` (re)starts the detector; `admit` calls it, so a grant
    /// given after launch brings the detector up on the next acting call.
    public init(rule: TakeoverRule = TakeoverRule(), now: @escaping Clock = TakeoverGate.uptimeNanos,
                sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
                starter: (@Sendable () -> Void)? = nil) {
        self.rule = rule
        self.now = now
        self.sleep = sleep
        self.starter = starter
    }

    public static let uptimeNanos: Clock = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    // MARK: Fed by the tap

    public func setHealthy(_ healthy: Bool) {
        state.withLock { $0.healthy = healthy }
    }

    /// Record one classified event seen at `at` (uptime nanoseconds).
    public func observe(_ provenance: InputProvenance, x: Double = 0, y: Double = 0, at: UInt64? = nil) {
        let at = at ?? now()
        state.withLock { state in
            switch provenance {
            case .agent:
                state.stats.agentEvents += 1
            case .person:
                state.stats.personEvents += 1
                if !Self.personHolds(state, rule: rule, at: at) { state.stats.takeovers += 1 }
                state.lastPerson = at
                state.pointer = PointerSample(x: x, y: y, atNanos: at)
            case .personPointer:
                state.pointer = PointerSample(x: x, y: y, atNanos: at)
            case .ignored:
                break
            }
        }
    }

    // MARK: Read

    public func holder() -> ControlHolder {
        let at = now()
        return state.withLock { Self.holder($0, rule: rule, at: at) }
    }

    public func personPointer() -> PointerSample? {
        state.withLock { $0.pointer }
    }

    public func snapshot() -> TakeoverStats {
        state.withLock { $0.stats }
    }

    // MARK: The execution boundary

    /// Returns when `tool` may run. Observing calls return at once; acting
    /// calls wait while the person is driving, up to `rule.hold`, and then
    /// throw `TakeoverRefusal`.
    public func admit(_ tool: String, requirement: ConsentRequirement) async throws {
        guard requirement == .act else { return }
        starter?()
        let start = now()
        let deadline = start &+ UInt64(rule.hold.totalNanos)
        var waited = false
        while true {
            let at = now()
            guard case .person(let resumesAt) = state.withLock({ Self.holder($0, rule: rule, at: at) }) else {
                if waited { state.withLock { $0.stats.held += 1 } }
                return
            }
            if resumesAt > deadline || at >= deadline {
                state.withLock { $0.stats.refused += 1 }
                throw TakeoverRefusal(tool: tool)
            }
            waited = true
            // timeout: the person's own quiet period, never longer than rule.hold in total.
            try await sleep(.nanoseconds(Int64(resumesAt - at)))
        }
    }

    private static func holder(_ state: State, rule: TakeoverRule, at: UInt64) -> ControlHolder {
        guard state.healthy else { return .unwatched }
        guard let last = state.lastPerson else { return .agent }
        let resumesAt = last &+ UInt64(rule.quiet.totalNanos)
        return at < resumesAt ? .person(resumesAt: resumesAt) : .agent
    }

    private static func personHolds(_ state: State, rule: TakeoverRule, at: UInt64) -> Bool {
        guard let last = state.lastPerson else { return false }
        return at < last &+ UInt64(rule.quiet.totalNanos)
    }
}

extension Duration {
    var totalNanos: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}
