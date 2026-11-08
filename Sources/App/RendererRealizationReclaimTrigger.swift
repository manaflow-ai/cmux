import Foundation

/// Reason a renderer realization pass is selecting surfaces to reclaim.
enum RendererRealizationReclaimTrigger: Equatable, Sendable {
    case scheduled
    case systemMemoryPressure
}
