import CCmuxMotionFFI
import Foundation

/// The C forms of `HoverIntent`'s targets and effects: each target as the 64-bit handle
/// cmux-motion's hover intent compares, and its effects from the `cmux_motion_ffi.h` struct. No
/// rule lives here; the intent is Rust's.
nonisolated struct HoverIntentHandles<Target: Hashable & Sendable>: Sendable {
    private var handles: [Target: UInt64] = [:]
    private var targets: [UInt64: Target] = [:]
    private var nextHandle: UInt64 = 1

    /// `target`'s handle, a fresh one for a target not held.
    mutating func handle(_ target: Target) -> UInt64 {
        if let known = handles[target] { return known }
        let fresh = nextHandle
        nextHandle &+= 1
        handles[target] = fresh
        targets[fresh] = target
        return fresh
    }

    /// The target of `handle`, nil for one no longer held.
    func target(_ handle: UInt64) -> Target? { targets[handle] }

    /// The C effects as Swift effects, in order (kind 0 schedule, 1 cancelTimer, 2 show, 3 hide).
    func effects(_ raw: some Sequence<CmuxHoverIntentEffect>) -> [HoverIntent<Target>.Effect] {
        raw.compactMap { (effect: CmuxHoverIntentEffect) -> HoverIntent<Target>.Effect? in
            switch effect.kind {
            case 0: .schedule(token: Int(truncatingIfNeeded: effect.token), after: Duration(hoverNanoseconds: effect.after))
            case 1: .cancelTimer
            case 2: targets[effect.target].map { .show($0) }
            case 3: .hide
            default: nil
            }
        }
    }

    /// Keeps only the handle `state`'s phase names (pending or shown): the rule compares a new
    /// target only with that one.
    mutating func prune(keeping state: CmuxHoverIntent) {
        let keep: UInt64? = state.phase == 1 || state.phase == 2 ? state.target : nil
        guard targets.count > (keep == nil ? 0 : 1) else { return }
        let kept = keep.flatMap { targets[$0] }
        targets.removeAll(keepingCapacity: true)
        handles.removeAll(keepingCapacity: true)
        if let keep, let kept {
            targets[keep] = kept
            handles[kept] = keep
        }
    }
}
