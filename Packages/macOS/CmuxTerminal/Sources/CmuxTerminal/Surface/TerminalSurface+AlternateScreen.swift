internal import Foundation
internal import GhosttyKit

extension TerminalSurface {
    /// Whether a full-screen application (vim, htop, less) has the terminal
    /// in the alternate screen right now.
    ///
    /// libghostty exposes the active screen only through the render-grid
    /// export, so this serializes the viewport. It is meant for occasional
    /// reads, such as when predictive echo starts for a surface, not for a
    /// per-keystroke or per-frame path.
    ///
    /// - Returns: `false` when the surface has no live runtime or the export
    ///   fails, which is also the state a new terminal starts in.
    @MainActor
    public func isAlternateScreenActive() -> Bool {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "alternateScreenRead") else {
            return false
        }
        let surfaceID = id.uuidString
        let exported = surfaceID.withCString { ptr in
            ghostty_surface_render_grid_json_v2(
                surface,
                ptr,
                UInt(surfaceID.utf8.count),
                0,
                0,
                false,
                false
            )
        }
        defer { ghostty_string_free(exported) }
        guard let ptr = exported.ptr, exported.len > 0 else { return false }
        let data = Data(bytes: ptr, count: Int(exported.len))
        return (try? JSONDecoder().decode(ActiveScreen.self, from: data))?.activeScreen == "alternate"
    }
}

/// The one field of the render-grid export this reads.
private struct ActiveScreen: Decodable {
    let activeScreen: String

    enum CodingKeys: String, CodingKey {
        case activeScreen = "active_screen"
    }
}
