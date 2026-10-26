// Intent prewarm's pure state (p04-input-042/043/044): the held prewarms and what started them (its inputs
// and counters are in IntentPrewarmInputs.swift). The main-actor service (CmuxNextInput's IntentPrewarmService) owns the dwell timer,
// the pressure and power gating and the calls into the warmer; the decisions are here.

/// What started a prewarm, after Chrome's speculation-rules eagerness: `conservative` starts on
/// pointerdown, `moderate` after the pointer rests 200 ms on the link
/// (third_party/blink/renderer/core/html/anchor_element_interaction_tracker.cc, `kHoverEventDelay`).
public enum IntentPrewarmTrigger: String, Sendable, CaseIterable {
    /// A press on a target that commits on release (p04-input-042).
    case pointerDown
    /// The pointer rested on a target for the service's dwell (p04-input-043).
    case hoverDwell
    /// A next/previous key stepped toward the target (p04-input-044).
    case keyStep
}

/// Which way a next/previous key stepped (p04-input-044): a step the other way cancels what the old
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

/// The held prewarms, oldest first, at most ``limit``: a new one past the limit evicts the oldest, as
/// Chrome holds at most two non-eager prerenders and cancels the oldest
/// (content/browser/preloading/prerender/prerender_host_registry.cc,
/// `kMaxNumOfRunningNonEagerPrerendersExceeded`).
public struct IntentPrewarmQueue<Target: Hashable & Sendable>: Sendable, Equatable {
    /// How many prewarms are held at once (2 by default, Chrome's non-eager prerender limit).
    public let limit: Int
    /// The held prewarms, oldest first.
    public private(set) var held: [Target] = []

    public init(limit: Int = 2) {
        self.limit = max(limit, 1)
    }

    /// `target` is held.
    public func contains(_ target: Target) -> Bool { held.contains(target) }

    /// Holds `target` as the newest; returns the oldest when the limit evicted it. Holding a target
    /// already held changes nothing and evicts nothing.
    public mutating func admit(_ target: Target) -> Target? {
        guard !held.contains(target) else { return nil }
        held.append(target)
        return held.count > limit ? held.removeFirst() : nil
    }

    /// Lets `target` go without a cancel (it committed, or its content went); false when it was not held.
    @discardableResult
    public mutating func remove(_ target: Target) -> Bool {
        guard let index = held.firstIndex(of: target) else { return false }
        held.remove(at: index)
        return true
    }

    /// Lets every held prewarm go and returns them, oldest first (critical memory pressure cancels them).
    public mutating func removeAll() -> [Target] {
        defer { held.removeAll() }
        return held
    }
}
