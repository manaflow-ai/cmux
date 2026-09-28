import Foundation

/// The terminals a phone currently renders, declared to the Mac through
/// `mobile.terminal.view_set`; the Mac captures and sends render grids for
/// these terminals only.
///
/// Each declaration replaces the previous one for the connection. A
/// connection that never declares receives every terminal.
public struct MobileTerminalViewSet: Equatable, Sendable {
    public static let method = "mobile.terminal.view_set"
    public static let capability = "terminal.render_grid.view_set.v1"
    public static let surfaceIDsParameterKey = "surface_ids"
    /// A phone renders a handful of terminals; a larger set is a bug, not a
    /// layout, and is rejected instead of silently truncated.
    public static let maximumSurfaceCount = 64

    public var surfaceIDs: Set<UUID>

    public init(surfaceIDs: Set<UUID>) {
        self.surfaceIDs = surfaceIDs
    }

    /// The declared set, or nil when the parameter is missing, too large or
    /// names something that is not a terminal id.
    public init?(params: [String: Any]) {
        guard let raw = params[Self.surfaceIDsParameterKey] as? [String],
              raw.count <= Self.maximumSurfaceCount else { return nil }
        var surfaceIDs = Set<UUID>()
        for value in raw {
            guard let surfaceID = UUID(uuidString: value) else { return nil }
            surfaceIDs.insert(surfaceID)
        }
        self.surfaceIDs = surfaceIDs
    }

    public var params: [String: Any] {
        [Self.surfaceIDsParameterKey: surfaceIDs.map(\.uuidString).sorted()]
    }
}
