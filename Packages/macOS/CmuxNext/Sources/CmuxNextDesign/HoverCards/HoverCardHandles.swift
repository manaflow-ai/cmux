import CCmuxMotionFFI
import Foundation
import CmuxNextDesignTokens

/// The C forms of `HoverCardMachine`'s inputs and outputs: each `HoverTargetID` as the 64-bit
/// handle cmux-motion's hover card machine compares, and the events and effects as the
/// `cmux_motion_ffi.h` structs. No rule lives here; the machine is Rust's.
nonisolated struct HoverCardHandles: Sendable {
    private var handles: [HoverTargetID: UInt64] = [:]
    private var ids: [UInt64: HoverTargetID] = [:]
    private var nextHandle: UInt64 = 1

    /// `HoverSuppression` in the rule's bit order (bit 0 drag, 1 scroll, 2 sidebarHide).
    static let suppressionOrder: [HoverSuppression] = [.drag, .scroll, .sidebarHide]

    /// `event` as the C event (kind numbers as in `cmux_motion_ffi.h`).
    mutating func cEvent(_ event: HoverCardEvent) -> CmuxHoverCardEvent {
        var raw = CmuxHoverCardEvent()
        switch event {
        case .hit(let target, let moved, let aiming, let bridging):
            raw.kind = 0
            raw.flag = target != nil
            if let target { raw.target = cTarget(target) }
            raw.moved = moved
            raw.aiming = aiming
            raw.bridging = bridging
        case .pointerOnCard(let on):
            raw.kind = 1
            raw.flag = on
        case .deadline(let token):
            raw.kind = 2
            raw.token = UInt64(truncatingIfNeeded: token)
        case .dismiss:
            raw.kind = 3
        case .suppress(let reason):
            raw.kind = 4
            raw.suppression = Self.bit(reason)
        case .unsuppress(let reason):
            raw.kind = 5
            raw.suppression = Self.bit(reason)
        case .targetRemoved(let id):
            raw.kind = 6
            // An id with no handle is neither the last hit nor the active target: handle 0 matches none.
            raw.target.id = handles[id] ?? 0
        case .pin(let target):
            raw.kind = 7
            raw.target = cTarget(target)
        case .owned(let shown):
            raw.kind = 8
            raw.flag = shown
        }
        return raw
    }

    /// The C effects as Swift effects, in order (kind 0 schedule, 1 cancelTimer, 2 show, 3 hide).
    func effects(_ raw: some Sequence<CmuxHoverCardEffect>) -> [HoverCardEffect] {
        raw.compactMap { (effect: CmuxHoverCardEffect) -> HoverCardEffect? in
            switch effect.kind {
            case 0: .schedule(token: Int(truncatingIfNeeded: effect.token), after: Duration(hoverNanoseconds: effect.after))
            case 1: .cancelTimer
            case 2: target(effect.target).map { .show($0, sliding: effect.sliding) }
            case 3: .hide
            default: nil
            }
        }
    }

    /// The target the C target names, nil for a handle no longer held.
    func target(_ raw: CmuxHoverTarget) -> HoverTarget? {
        guard let id = ids[raw.id] else { return nil }
        let leave: HoverCardLeave = raw.leave == 1 ? .hides(reshow: Duration(hoverNanoseconds: raw.reshow)) : .lingers
        return HoverTarget(id: id, window: Int(truncatingIfNeeded: raw.window), delay: Duration(hoverNanoseconds: raw.delay), leave: leave)
    }

    /// Keeps only the handles `state` names (its phase's target and the last hit): the rule
    /// compares a new target only with those, so a dropped id gets a fresh handle when it returns.
    mutating func prune(keeping state: CmuxHoverCardMachine) {
        let phaseHolds = (1...4).contains(state.phase)
        let keep = Set([phaseHolds ? state.target.id : nil, state.has_last_hit ? state.last_hit.id : nil].compactMap(\.self))
        guard ids.count > keep.count else { return }
        ids = ids.filter { keep.contains($0.key) }
        handles = handles.filter { keep.contains($0.value) }
    }

    private static func bit(_ reason: HoverSuppression) -> UInt8 {
        UInt8(suppressionOrder.firstIndex(of: reason) ?? 0)
    }

    private mutating func cTarget(_ target: HoverTarget) -> CmuxHoverTarget {
        var raw = CmuxHoverTarget()
        raw.id = handle(target.id)
        raw.window = Int64(truncatingIfNeeded: target.window)
        raw.delay = target.delay.hoverNanoseconds
        if case .hides(let reshow) = target.leave {
            raw.leave = 1
            raw.reshow = reshow.hoverNanoseconds
        }
        return raw
    }

    private mutating func handle(_ id: HoverTargetID) -> UInt64 {
        if let known = handles[id] { return known }
        let fresh = nextHandle
        nextHandle &+= 1
        handles[id] = fresh
        ids[fresh] = id
        return fresh
    }
}
