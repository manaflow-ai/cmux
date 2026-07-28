import Foundation

/// One terminal surface's state for the renderer-reclamation decision.
struct RendererRealizationPlannerInput: Sendable {
    let surfaceId: UUID
    let isVisible: Bool
    let isRealized: Bool
    let lastVisibleAt: TimeInterval
}

/// Pure policy for which offscreen terminal surfaces should release their GPU
/// renderer. Keeps the `maxWarmRenderers` most-recently-visible realized
/// surfaces warm while they are under the idle threshold, and immediately
/// releases hidden realized surfaces outside that warm set so the cap remains a
/// hard high-water mark. A currently-visible surface is never selected.
enum RendererRealizationPlanner {
    static func selectedSurfaceIds(
        inputs: [RendererRealizationPlannerInput],
        settings: RendererRealizationSettings.Values,
        now: TimeInterval,
        trigger: RendererRealizationReclaimTrigger = .scheduled
    ) -> Set<UUID> {
        guard settings.enabled else { return [] }

        if trigger == .systemMemoryPressure {
            return Set(
                inputs.lazy
                    .filter { $0.isRealized && !$0.isVisible }
                    .map(\.surfaceId)
            )
        }

        // Only realized surfaces hold releasable GPU resources. Rank by recency
        // (most-recent first); visible surfaces are stamped ~now so they sort to
        // the top and land inside the warm set.
        let ranked = inputs
            .filter { $0.isRealized }
            .sorted { lhs, rhs in
                if lhs.lastVisibleAt == rhs.lastVisibleAt {
                    return lhs.surfaceId.uuidString < rhs.surfaceId.uuidString
                }
                return lhs.lastVisibleAt > rhs.lastVisibleAt
            }

        let warmCap = max(1, settings.maxWarmRenderers)
        var selected: Set<UUID> = []
        for (index, input) in ranked.enumerated() {
            if input.isVisible { continue }          // never release a visible surface
            if index >= warmCap {
                selected.insert(input.surfaceId)
                continue
            }
            guard now - input.lastVisibleAt >= settings.idleSeconds else { continue }
            selected.insert(input.surfaceId)
        }
        return selected
    }
}
