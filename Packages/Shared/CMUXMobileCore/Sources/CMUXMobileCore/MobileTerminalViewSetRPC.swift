import Foundation

/// Wire contract for `mobile.terminal.view_set`: the phone names every
/// terminal it currently renders, and the Mac captures and sends render grids
/// for those terminals only.
///
/// Each call replaces the previous set for the connection. A connection that
/// never calls it receives every terminal, which is the contract older phones
/// rely on. The phone sends it only to a Mac that advertises ``capability``.
public enum MobileTerminalViewSetRPC {
    public static let method = "mobile.terminal.view_set"
    public static let capability = "terminal.render_grid.view_set.v1"
    public static let surfaceIDsParameterKey = "surface_ids"
    /// A phone renders a handful of terminals; a larger set is a bug, not a
    /// layout, and is rejected instead of silently truncated.
    public static let maximumSurfaceCount = 64

    public static func params(surfaceIDs: Set<String>) -> [String: Any] {
        [surfaceIDsParameterKey: surfaceIDs.sorted()]
    }

    /// The declared surfaces, or nil when the parameter is missing, too large
    /// or names something that is not a terminal id.
    public static func surfaceIDs(from params: [String: Any]) -> Set<UUID>? {
        guard let raw = params[surfaceIDsParameterKey] as? [String],
              raw.count <= maximumSurfaceCount else { return nil }
        var surfaceIDs = Set<UUID>()
        for value in raw {
            guard let surfaceID = UUID(uuidString: value) else { return nil }
            surfaceIDs.insert(surfaceID)
        }
        return surfaceIDs
    }
}
