import Foundation

/// The render-grid surfaces one mobile event stream currently consumes.
///
/// A capable client includes this value under `render_grid_demand` in each
/// `mobile.events.subscribe` request. Re-subscribing the same stream identifier
/// atomically replaces its demand. An inactive demand retains unrelated event
/// topics while releasing all render-grid work.
public struct MobileRenderGridDemand: Codable, Equatable, Sendable {
    /// Whether the client is currently able to consume render-grid events.
    public var isActive: Bool
    /// Mounted terminal surfaces that require the existing full-rate path.
    public var focusedSurfaceIDs: Set<String>
    /// Lightweight preview surfaces that may be cadence-limited.
    public var previewSurfaceIDs: Set<String>

    /// Creates a render-grid demand declaration.
    /// - Parameters:
    ///   - isActive: Whether the client can currently consume frames.
    ///   - focusedSurfaceIDs: Mounted surfaces that need full-rate delivery.
    ///   - previewSurfaceIDs: Visible preview surfaces that accept throttling.
    public init(
        isActive: Bool = true,
        focusedSurfaceIDs: Set<String> = [],
        previewSurfaceIDs: Set<String> = []
    ) {
        self.isActive = isActive
        self.focusedSurfaceIDs = Set(focusedSurfaceIDs.filter { !$0.isEmpty })
        self.previewSurfaceIDs = Set(previewSurfaceIDs.filter { !$0.isEmpty })
    }

    /// The surfaces that consume frames while this demand is active.
    public var surfaceIDs: Set<String> {
        guard isActive else { return [] }
        return focusedSurfaceIDs.union(previewSurfaceIDs)
    }

    /// Whether this declaration consumes frames for a surface.
    /// - Parameter surfaceID: The terminal surface identifier to test.
    /// - Returns: `true` when the active focused or preview set contains it.
    public func contains(surfaceID: String) -> Bool {
        surfaceIDs.contains(surfaceID)
    }

    /// A deterministic JSON object suitable for an RPC parameter.
    /// - Returns: The wire representation of this demand.
    public func jsonObject() -> [String: Any] {
        [
            "active": isActive,
            "focused_surface_ids": focusedSurfaceIDs.sorted(),
            "preview_surface_ids": previewSurfaceIDs.sorted(),
        ]
    }

    /// Decodes a demand from an RPC parameter object.
    /// - Parameter object: The JSON-compatible value under `render_grid_demand`.
    /// - Returns: A validated demand, or `nil` for an invalid object.
    public static func decodeJSONObject(_ object: Any) -> MobileRenderGridDemand? {
        guard let object = object as? [String: Any],
              let isActive = object["active"] as? Bool,
              let focused = object["focused_surface_ids"] as? [String],
              let previews = object["preview_surface_ids"] as? [String] else {
            return nil
        }
        return MobileRenderGridDemand(
            isActive: isActive,
            focusedSurfaceIDs: Set(focused),
            previewSurfaceIDs: Set(previews)
        )
    }

    enum CodingKeys: String, CodingKey {
        case isActive = "active"
        case focusedSurfaceIDs = "focused_surface_ids"
        case previewSurfaceIDs = "preview_surface_ids"
    }
}
