// Intent prewarm's pure state: the held prewarms and what started them (its inputs
// and counters are in IntentPrewarmInputs.swift). The main-actor service (CmuxNextInput's IntentPrewarmService) owns the dwell timer,
// the pressure and power gating and the calls into the warmer; the decisions are here.

/// What started a prewarm, after Chrome's speculation-rules eagerness: `conservative` starts on
/// pointerdown, `moderate` after the pointer rests 200 ms on the link
/// (third_party/blink/renderer/core/html/anchor_element_interaction_tracker.cc, `kHoverEventDelay`).
public enum IntentPrewarmTrigger: String, Sendable, CaseIterable {
    /// A press on a target that commits only on its release: the press-to-release time is
    /// the head start.
    case pointerDown
    /// The pointer rested on a target for the service's dwell.
    case hoverDwell
    /// A next/previous key stepped toward the target.
    case keyStep
}

/// Which way a next/previous key stepped: a step the other way cancels what the old
/// direction prewarmed.
public enum IntentPrewarmDirection: Sendable, Equatable {
    /// Next.
    case forward
    /// Previous.
    case backward

    /// The direction of a step by `offset` (`+1` Next, `-1` Previous); nil for no step.
    public init?(offset: Int) {
        guard offset != 0 else { return nil }
        self = offset > 0 ? .forward : .backward
    }
}

/// The held prewarms, oldest first, at most ``limit``, each with the trigger that started it: a new one past the
/// limit evicts the oldest, as Chrome holds at most two non-eager prerenders and cancels the oldest
/// (content/browser/preloading/prerender/prerender_host_registry.cc,
/// `kMaxNumOfRunningNonEagerPrerendersExceeded`). Each `PrerenderHost` keeps its trigger the same way, so a
/// cancel scoped to one trigger never reaches another's, and a use is counted by trigger.
public struct IntentPrewarmQueue<Target: Hashable & Sendable>: Sendable, Equatable {
    /// How many prewarms are held at once (2 by default, Chrome's non-eager prerender limit).
    public let limit: Int
    /// The held prewarms, oldest first.
    public private(set) var held: [Target] = []
    /// What started each held prewarm; its keys are exactly `held`.
    private var triggers: [Target: IntentPrewarmTrigger] = [:]

    public init(limit: Int = 2) {
        self.limit = max(limit, 1)
    }

    /// `target` is held.
    public func contains(_ target: Target) -> Bool { triggers[target] != nil }

    /// What started `target`'s held prewarm; nil when it is not held.
    public func trigger(of target: Target) -> IntentPrewarmTrigger? { triggers[target] }

    /// Holds `target` as the newest, started by `trigger`; returns the oldest when the limit evicted it.
    /// Holding a target already held changes nothing (not its age, not its trigger) and evicts nothing.
    public mutating func admit(_ target: Target, trigger: IntentPrewarmTrigger) -> Target? {
        guard triggers[target] == nil else { return nil }
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
        guard let trigger = triggers.removeValue(forKey: target) else { return nil }
        held.removeAll { $0 == target }
        return trigger
    }

    /// Lets every held prewarm `trigger` started go and returns them, oldest first (a key step the other way
    /// cancels the old direction's).
    public mutating func removeAll(startedBy trigger: IntentPrewarmTrigger) -> [Target] {
        let (dropped, kept) = held.reduce(into: ([Target](), [Target]())) { split, target in
            if triggers[target] == trigger { split.0.append(target) } else { split.1.append(target) }
        }
        held = kept
        for target in dropped { triggers[target] = nil }
        return dropped
    }

    /// Lets every held prewarm go and returns them, oldest first (critical memory pressure cancels them).
    public mutating func removeAll() -> [Target] {
        let dropped = held
        held.removeAll()
        triggers.removeAll()
        return dropped
    }
}
