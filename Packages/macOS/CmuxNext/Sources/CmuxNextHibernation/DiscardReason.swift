/// Why the planner is asked to discard: Chrome's `LifecycleUnitDiscardReason`
/// (chrome/browser/resource_coordinator/lifecycle_unit_state.mojom), without `SUGGESTED` (cmux
/// suggests no discards).
package nonisolated enum DiscardReason: String, Hashable, Sendable, CaseIterable {
    /// The content was hidden past its timeout, with no memory pressure (Memory Saver).
    case proactive
    /// Memory pressure: content goes before its timeout to relieve it.
    case urgent
    /// The person or a script asked for it (Hibernate Tab): only ``CanDiscardResult/disallowed``
    /// reasons keep the content.
    case external
    /// Frozen content whose memory kept growing (Chrome's `kFreezingMemoryGrowthThresholdToDiscardKb`).
    case frozenWithGrowingMemory = "frozen_with_growing_memory"
}
