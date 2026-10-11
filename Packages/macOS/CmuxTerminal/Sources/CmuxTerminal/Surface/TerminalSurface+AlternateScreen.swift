internal import Foundation
internal import GhosttyKit

extension TerminalSurface {
    /// Whether a full-screen application (vim, htop, less) has the terminal
    /// in the alternate screen right now.
    ///
    /// libghostty exposes the active screen only through the render-grid
    /// export, so every call serializes the viewport to a JSON string. Reading
    /// the marker skips the Swift-side decode but not that serialization.
    ///
    /// Keystroke callers are expected, since `terminalAlternateScreen` gates
    /// shortcuts and can only be answered when the key is pressed. They must
    /// memoize: the shortcut dispatcher caches per event, and the text-editing
    /// gestures cache per held key, so the cost is one read per distinct press
    /// rather than per repeat or per frame. A caller that reads this on every
    /// frame, or on every repeat of a held key, is a bug.
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
        return Self.renderGridExportIsAlternateScreen(data)
    }

    /// Reads `active_screen` from a render-grid export without decoding the
    /// whole grid.
    ///
    /// The field is written after the row spans, so the scan runs from the
    /// end. Row text is JSON-escaped, so every quote inside it follows a
    /// backslash and cannot form the unescaped `"active_screen":"` key. An
    /// export in another layout falls back to a full decode.
    static func renderGridExportIsAlternateScreen(_ data: Data) -> Bool {
        if data.range(of: alternateScreenMarker, options: .backwards) != nil {
            return true
        }
        if data.range(of: primaryScreenMarker, options: .backwards) != nil {
            return false
        }
        return (try? JSONDecoder().decode(ActiveScreen.self, from: data))?.activeScreen == "alternate"
    }

    private static let alternateScreenMarker = Data(#""active_screen":"alternate""#.utf8)
    private static let primaryScreenMarker = Data(#""active_screen":"primary""#.utf8)
}

/// The one field of the render-grid export this reads.
private struct ActiveScreen: Decodable {
    let activeScreen: String

    enum CodingKeys: String, CodingKey {
        case activeScreen = "active_screen"
    }
}
