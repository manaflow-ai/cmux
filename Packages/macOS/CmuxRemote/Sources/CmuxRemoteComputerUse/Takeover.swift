// SPDX-License-Identifier: GPL-3.0-or-later
// The takeover rule follows Petal's ai_chat/takeover.rs and control_gate.rs
// (kiruna-labs/petal @ 7ac436a, Apache-2.0, Copyright Kiruna Labs), ported
// to Swift (first for the Computer Use helper v2, #36080), now the Computer Use
// worker's `wait_idle` for libcmux_computer_use.
import Foundation
import os

/// Where an input event came from, as the takeover tap sees it.
enum InputProvenance: Sendable, Equatable {
    /// Our own input: it carries `TakeoverMarker`, or this process (where
    /// libcmux_computer_use runs) posted it.
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

    /// Without Input Monitoring: everything but keys, so creating the tap
    /// never asks for that grant. Clicks, drags and scrolls still take over.
    static var pointerOnlyMask: UInt64 {
        mask & ~(1 << UInt64(keyDown))
    }
}

/// Classify one event. Pure, so the rule is testable without a window
/// server. An event with our marker or our pid is ours whatever its type;
/// anything else that is deliberate input is the person's. A wrong guess
/// errs toward the person: it pauses the agent rather than letting it act
/// over someone.
func classifyInput(type: UInt32, userData: Int64, sourcePID: Int64, ownPID: Int64) -> InputProvenance {
    if userData == TakeoverMarker.value || (sourcePID != 0 && sourcePID == ownPID) { return .agent }
    if TapEventType.deliberate.contains(type) { return .person }
    if TapEventType.pointer.contains(type) { return .personPointer }
    return .ignored
}

/// When the agent may act while the person is using the Mac (the engine's
/// `wait_idle`, cmux_computer_use.h).
///
/// - The person takes over on any deliberate input of theirs (a key, a
///   click, a scroll, a drag). Moving the pointer alone does not.
/// - The agent resumes once the person has been quiet for `quiet`.
/// - An acting call waits for that quiet, up to the engine's limit; if the
///   person is still going it gets `false` (the engine refuses the call).
/// - With no working detector (no tap, or our marker did not come back)
///   the person counts as idle: Computer Use works rather than failing on a
///   missing grant.
struct TakeoverRule: Sendable, Equatable {
    var quiet: Duration

    init(quiet: Duration = .milliseconds(1500)) {
        self.quiet = quiet
    }
}

/// Who has the machine right now.
enum ControlHolder: Sendable, Equatable {
    case agent
    /// The person, until `resumesAt` (uptime nanoseconds) unless they act again.
    case person(resumesAt: UInt64)
    /// The detector is not running or could not prove provenance.
    case unwatched
}

/// The person's latest pointer position: global display points, top-left
/// origin, and when it was seen (uptime nanoseconds).
struct PointerSample: Sendable, Equatable {
    var x: Double
    var y: Double
    var atNanos: UInt64
}

/// Counters for status, read with `TakeoverGate.snapshot()`.
struct TakeoverStats: Sendable, Equatable {
    var agentEvents: UInt64 = 0
    var personEvents: UInt64 = 0
    /// Transitions from the agent to the person.
    var takeovers: UInt64 = 0
    /// Waits that ended with the person quiet.
    var held: UInt64 = 0
    /// Waits that ran out while the person kept going.
    var refused: UInt64 = 0
}

/// The takeover state. The tap feeds it events; the engine's `wait_idle`
/// (`waitIdle(limit:)`) runs right before each acting call.
final class TakeoverGate: Sendable {
    typealias Clock = @Sendable () -> UInt64
    /// Blocks the calling (engine) thread for a duration; a test advances its own clock.
    typealias Sleeper = @Sendable (Duration) -> Void

    private struct State {
        var healthy = false
        var lastPerson: UInt64?
        var pointer: PointerSample?
        var stats = TakeoverStats()
    }

    let rule: TakeoverRule
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let now: Clock
    private let sleep: Sleeper
    private let starter: (@Sendable () -> Void)?

    /// `starter` (re)starts the detector; `waitIdle` calls it, so a grant
    /// given after launch brings the detector up on the next acting call.
    init(rule: TakeoverRule = TakeoverRule(), now: @escaping Clock = TakeoverGate.uptimeNanos,
         sleep: @escaping Sleeper = TakeoverGate.timedWait, starter: (@Sendable () -> Void)? = nil) {
        self.rule = rule
        self.now = now
        self.sleep = sleep
        self.starter = starter
    }

    static let uptimeNanos: Clock = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// A timed wait on the engine's thread (never the main thread): the person's own quiet
    /// period, bounded by the engine's `limit_ms`. A condition nobody signals, so it is the
    /// timeout itself, not a synchronization.
    static let timedWait: Sleeper = { duration in
        let condition = NSCondition()
        condition.lock()
        // timeout: the rest of the person's quiet period, never past the engine's limit.
        _ = condition.wait(until: Date().addingTimeInterval(Double(duration.totalNanos) / 1e9))
        condition.unlock()
    }

    // MARK: Fed by the tap

    func setHealthy(_ healthy: Bool) {
        state.withLock { $0.healthy = healthy }
    }

    /// Record one classified event seen at `at` (uptime nanoseconds).
    func observe(_ provenance: InputProvenance, x: Double = 0, y: Double = 0, at: UInt64? = nil) {
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

    func holder() -> ControlHolder {
        let at = now()
        return state.withLock { Self.holder($0, rule: rule, at: at) }
    }

    func personPointer() -> PointerSample? {
        state.withLock { $0.pointer }
    }

    func snapshot() -> TakeoverStats {
        state.withLock { $0.stats }
    }

    /// The person's deliberate inputs counted so far, or nil while nothing
    /// watches them (no tap, or provenance unproven). The engine's focus
    /// guard compares two readings to know whether the person moved focus
    /// during a call, so it never puts focus back over them.
    func personEventCount() -> UInt64? {
        state.withLock { $0.healthy ? $0.stats.personEvents : nil }
    }

    // MARK: The engine's wait_idle

    /// Blocks while the person is driving, up to `limit`; true when they are
    /// idle (or nothing watches them), false when the limit ran out first.
    func waitIdle(limit: Duration) -> Bool {
        starter?()
        let deadline = now() &+ UInt64(max(limit.totalNanos, 0))
        var waited = false
        while true {
            let at = now()
            guard case .person(let resumesAt) = state.withLock({ Self.holder($0, rule: rule, at: at) }) else {
                if waited { state.withLock { $0.stats.held += 1 } }
                return true
            }
            if at >= deadline {
                state.withLock { $0.stats.refused += 1 }
                return false
            }
            waited = true
            sleep(.nanoseconds(Int64(min(resumesAt, deadline) - at)))
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
