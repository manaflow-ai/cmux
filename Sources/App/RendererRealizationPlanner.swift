import Foundation

/// One terminal surface's state for the renderer-reclamation decision.
struct RendererRealizationPlannerInput: Sendable {
    let surfaceId: UUID
    let isVisible: Bool
    let isRealized: Bool
    let lastVisibleAt: TimeInterval
    let isProtectedForPresentation: Bool

    init(
        surfaceId: UUID,
        isVisible: Bool,
        isRealized: Bool,
        lastVisibleAt: TimeInterval,
        isProtectedForPresentation: Bool = false
    ) {
        self.surfaceId = surfaceId
        self.isVisible = isVisible
        self.isRealized = isRealized
        self.lastVisibleAt = lastVisibleAt
        self.isProtectedForPresentation = isProtectedForPresentation
    }
}

/// Pure policy for which offscreen terminal surfaces should release their GPU
/// renderer. Keeps the `maxWarmRenderers` most-recently-visible realized
/// surfaces warm (so switching among a working set stays instant), and releases
/// the rest only when they are offscreen and have been idle past `idleSeconds`.
/// A currently-visible surface is never selected.
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
                    .filter {
                        $0.isRealized &&
                            !$0.isVisible &&
                            !$0.isProtectedForPresentation
                    }
                    .map(\.surfaceId)
            )
        }

        // Only realized surfaces hold releasable GPU resources. Rank by recency
        // (most-recent first), with switch-protected surfaces pinned ahead of
        // the ordinary warm set so they consume its budget rather than extend it.
        let ranked = inputs
            .filter(\.isRealized)
            .sorted { lhs, rhs in
                if lhs.isProtectedForPresentation != rhs.isProtectedForPresentation {
                    return lhs.isProtectedForPresentation
                }
                if lhs.lastVisibleAt == rhs.lastVisibleAt {
                    return lhs.surfaceId.uuidString < rhs.surfaceId.uuidString
                }
                return lhs.lastVisibleAt > rhs.lastVisibleAt
            }

        let warmCap = max(1, settings.maxWarmRenderers)
        var selected: Set<UUID> = []
        for (index, input) in ranked.enumerated() {
            if index < warmCap { continue }          // keep the most-recent N warm
            if input.isVisible { continue }          // never release a visible surface
            if input.isProtectedForPresentation { continue }
            guard now - input.lastVisibleAt >= settings.idleSeconds else { continue }
            selected.insert(input.surfaceId)
        }
        return selected
    }
}
