// Intent prewarm's pure state (p04-input-042/043): the held prewarms and what started them (its inputs
// and counters are in IntentPrewarmInputs.swift). The main-actor service (CmuxNextInput's IntentPrewarmService) owns the dwell timer,
// the pressure and power gating and the calls into the warmer; the decisions are here.

/// What started a prewarm, after Chrome's speculation-rules eagerness: `conservative` starts on
/// pointerdown, `moderate` after the pointer rests 200 ms on the link
/// (third_party/blink/renderer/core/html/anchor_element_interaction_tracker.cc, `kHoverEventDelay`).
public enum IntentPrewarmTrigger: String, Sendable, CaseIterable {
    /// A press on a target that commits only on its release (p04-input-042): the press-to-release time is
    /// the head start.
    case pointerDown
    /// The pointer rested on a target for the service's dwell (p04-input-043).
    case hoverDwell
}

/// The held prewarms, oldest first, at most ``limit``: a new one past the limit evicts the oldest, as
/// Chrome holds at most two non-eager prerenders and cancels the oldest
/// (content/browser/preloading/prerender/prerender_host_registry.cc,
/// `kMaxNumOfRunningNonEagerPrerendersExceeded`). Hover and press prewarms share it: one FIFO, each held
/// prewarm remembering its trigger so a use is counted by trigger.
public struct IntentPrewarmQueue<Target: Hashable & Sendable>: Sendable, Equatable {
    /// How many prewarms are held at once (2 by default, Chrome's non-eager prerender limit).
    public let limit: Int
    /// The held prewarms, oldest first.
    public private(set) var held: [Target] = []
    /// What started each held prewarm; the keys are exactly ``held``.
    public private(set) var triggers: [Target: IntentPrewarmTrigger] = [:]

    public init(limit: Int = 2) {
        self.limit = max(limit, 1)
    }

    /// `target` is held.
    public func contains(_ target: Target) -> Bool { held.contains(target) }

    /// Holds `target` as the newest, started by `trigger`; returns the oldest when the limit evicted it.
    /// Holding a target already held changes nothing (its trigger and age included) and evicts nothing.
    public mutating func admit(_ target: Target, by trigger: IntentPrewarmTrigger) -> Target? {
        guard !held.contains(target) else { return nil }
        held.append(target)
        triggers[target] = trigger
        guard held.count > limit else { return nil }
        let evicted = held.removeFirst()
        triggers[evicted] = nil
        return evicted
    }

    /// Lets `target` go without a cancel (it committed, or its content went); returns the trigger that
    /// started it, nil when it was not held.
    @discardableResult
    public mutating func remove(_ target: Target) -> IntentPrewarmTrigger? {
        guard let index = held.firstIndex(of: target) else { return nil }
        held.remove(at: index)
        return triggers.removeValue(forKey: target)
    }

    /// Lets every held prewarm go and returns them, oldest first (critical memory pressure cancels them).
    public mutating func removeAll() -> [Target] {
        defer {
            held.removeAll()
            triggers.removeAll()
        }
        return held
    }
}
