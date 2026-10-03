import CmuxSurfaceCatalogModel

/// Pure Cloud projection decisions shared by reconciliation and its tests.
public enum CloudWorkspaceProjectionPolicy {
    /// Returns whether an unavailable display or forwarded-port preview can be
    /// skipped so the bound workspace can continue converging.
    public static func shouldSkipMissingLocalPreview(
        _ placement: SurfaceResourcePlacement,
        error: any Error
    ) -> Bool {
        guard placement.resource.kind == .display || placement.resource.isForwardedPort else { return false }
        guard let catalogError = error as? SurfaceCatalogError,
              case .unavailable = catalogError else { return false }
        return true
    }
}
