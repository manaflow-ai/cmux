import Foundation

/// Mutable delivery and throttle state owned for exactly one preview surface.
@MainActor
final class PreviewGridSurfaceState {
    var accumulator = PreviewGridAccumulator()
    var continuations: [UUID: AsyncStream<PreviewGridSnapshot>.Continuation] = [:]
    var lastPublishedAt: ContinuousClock.Instant?
    var pendingSnapshot: PreviewGridSnapshot?
    var pendingPublicationTask: Task<Void, Never>?
    var publicationCount = 0
}
