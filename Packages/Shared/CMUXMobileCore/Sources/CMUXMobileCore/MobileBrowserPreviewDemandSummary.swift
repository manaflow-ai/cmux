/// Aggregated browser-preview demand across event streams or client connections.
public struct MobileBrowserPreviewDemandSummary: Equatable, Sendable {
    /// Surfaces requesting compact card snapshots.
    public let previewSurfaceIDs: Set<String>
    /// Surfaces requesting full-screen snapshots.
    public let fullSurfaceIDs: Set<String>

    /// Aggregates active demand declarations, with full-screen demand winning.
    /// - Parameter demands: Demand declarations to combine.
    public init<S: Sequence>(demands: S) where S.Element == MobileBrowserPreviewDemand {
        var previews = Set<String>()
        var full = Set<String>()
        for demand in demands where demand.isActive {
            previews.formUnion(demand.previewSurfaceIDs)
            full.formUnion(demand.fullSurfaceIDs)
        }
        previews.subtract(full)
        previewSurfaceIDs = previews
        fullSurfaceIDs = full
    }

    /// Whether any browser snapshot work is currently demanded.
    public var hasDemand: Bool {
        !previewSurfaceIDs.isEmpty || !fullSurfaceIDs.isEmpty
    }

    /// Every explicitly demanded browser surface.
    public var surfaceIDs: Set<String> {
        previewSurfaceIDs.union(fullSurfaceIDs)
    }

    /// Returns the effective resolution requested for a surface.
    /// - Parameter surfaceID: The browser surface identifier to classify.
    /// - Returns: Full or preview fidelity, or `nil` when no client wants it.
    public func resolution(for surfaceID: String) -> MobileBrowserPreviewResolution? {
        if fullSurfaceIDs.contains(surfaceID) { return .full }
        if previewSurfaceIDs.contains(surfaceID) { return .preview }
        return nil
    }
}
