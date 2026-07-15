import Foundation

/// The Mac browser surfaces one mobile event stream currently consumes.
///
/// A capable client includes this value under `browser_preview_demand` in each
/// `mobile.events.subscribe` request. Re-subscribing the same stream identifier
/// atomically replaces its demand. Full-resolution demand wins when a surface is
/// present in both sets.
public struct MobileBrowserPreviewDemand: Codable, Equatable, Sendable {
    /// Whether the client is currently able to consume browser preview events.
    public var isActive: Bool
    /// Browser surfaces visible only as hub or strip cards.
    public var previewSurfaceIDs: Set<String>
    /// Browser surfaces currently open in the full-screen view-only experience.
    public var fullSurfaceIDs: Set<String>

    /// Creates a browser-preview demand declaration.
    /// - Parameters:
    ///   - isActive: Whether the client can currently consume frames.
    ///   - previewSurfaceIDs: Surfaces requesting compact card snapshots.
    ///   - fullSurfaceIDs: Surfaces requesting larger full-screen snapshots.
    public init(
        isActive: Bool = true,
        previewSurfaceIDs: Set<String> = [],
        fullSurfaceIDs: Set<String> = []
    ) {
        self.isActive = isActive
        self.previewSurfaceIDs = Set(previewSurfaceIDs.filter { !$0.isEmpty })
        self.fullSurfaceIDs = Set(fullSurfaceIDs.filter { !$0.isEmpty })
    }

    /// The surfaces that consume snapshots while this demand is active.
    public var surfaceIDs: Set<String> {
        guard isActive else { return [] }
        return previewSurfaceIDs.union(fullSurfaceIDs)
    }

    /// Returns the effective resolution requested for a surface.
    /// - Parameter surfaceID: The browser surface identifier to classify.
    /// - Returns: Full or preview fidelity, or `nil` when the surface is not demanded.
    public func resolution(for surfaceID: String) -> MobileBrowserPreviewResolution? {
        guard isActive else { return nil }
        if fullSurfaceIDs.contains(surfaceID) { return .full }
        if previewSurfaceIDs.contains(surfaceID) { return .preview }
        return nil
    }

    /// A deterministic JSON object suitable for an RPC parameter.
    /// - Returns: The wire representation of this demand.
    public func jsonObject() -> [String: Any] {
        [
            "active": isActive,
            "preview_surface_ids": previewSurfaceIDs.sorted(),
            "full_surface_ids": fullSurfaceIDs.sorted(),
        ]
    }

    /// Decodes a demand from an RPC parameter object.
    /// - Parameter object: The JSON-compatible value under `browser_preview_demand`.
    /// - Returns: A validated demand, or `nil` for an invalid object.
    public static func decodeJSONObject(_ object: Any) -> MobileBrowserPreviewDemand? {
        guard let object = object as? [String: Any],
              let isActive = object["active"] as? Bool,
              let previews = object["preview_surface_ids"] as? [String],
              let full = object["full_surface_ids"] as? [String] else {
            return nil
        }
        return MobileBrowserPreviewDemand(
            isActive: isActive,
            previewSurfaceIDs: Set(previews),
            fullSurfaceIDs: Set(full)
        )
    }

    enum CodingKeys: String, CodingKey {
        case isActive = "active"
        case previewSurfaceIDs = "preview_surface_ids"
        case fullSurfaceIDs = "full_surface_ids"
    }
}
