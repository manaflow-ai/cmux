/// Aggregated render-grid demand across event streams or client connections.
public struct MobileRenderGridDemandSummary: Equatable, Sendable {
    /// Whether any compatibility client still requires every surface.
    public let includesLegacyAll: Bool
    /// Surfaces requiring the full-rate mounted-terminal path.
    public let focusedSurfaceIDs: Set<String>
    /// Preview-only surfaces eligible for cadence limiting.
    public let previewSurfaceIDs: Set<String>

    /// Aggregates a sequence of stream or connection demand scopes.
    /// - Parameter scopes: Demand declarations to combine.
    public init<S: Sequence>(scopes: S) where S.Element == MobileRenderGridDemandScope {
        var includesLegacyAll = false
        var focusedSurfaceIDs = Set<String>()
        var previewSurfaceIDs = Set<String>()
        for scope in scopes {
            switch scope {
            case .legacyAll:
                includesLegacyAll = true
            case .scoped(let demand) where demand.isActive:
                focusedSurfaceIDs.formUnion(demand.focusedSurfaceIDs)
                previewSurfaceIDs.formUnion(demand.previewSurfaceIDs)
            case .scoped:
                break
            }
        }
        previewSurfaceIDs.subtract(focusedSurfaceIDs)
        self.includesLegacyAll = includesLegacyAll
        self.focusedSurfaceIDs = focusedSurfaceIDs
        self.previewSurfaceIDs = previewSurfaceIDs
    }

    /// Whether any render-grid work is currently demanded.
    public var hasDemand: Bool {
        includesLegacyAll || !focusedSurfaceIDs.isEmpty || !previewSurfaceIDs.isEmpty
    }

    /// Explicitly demanded surfaces, excluding the unbounded legacy case.
    public var surfaceIDs: Set<String> {
        focusedSurfaceIDs.union(previewSurfaceIDs)
    }

    /// Whether a surface needs full-rate emission.
    /// - Parameter surfaceID: The terminal surface identifier to classify.
    /// - Returns: `true` for legacy-all or focused demand.
    public func isFocused(surfaceID: String) -> Bool {
        includesLegacyAll || focusedSurfaceIDs.contains(surfaceID)
    }

    /// Whether any client wants a surface.
    /// - Parameter surfaceID: The terminal surface identifier to test.
    /// - Returns: `true` for legacy-all, focused, or preview demand.
    public func contains(surfaceID: String) -> Bool {
        includesLegacyAll || surfaceIDs.contains(surfaceID)
    }
}
