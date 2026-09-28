internal import Foundation
internal import GhosttyKit

extension TerminalSurface {
    /// Whether the program reading this terminal has bracketed paste (DEC
    /// mode 2004) on, so a pasted newline arrives as text instead of Return.
    ///
    /// Shell line editors turn it on while they wait at a prompt and off
    /// while a command runs. libghostty exposes modes only through the
    /// render-grid export, so this serializes the viewport: fine for the
    /// occasional check before a paste, not for a per-frame path.
    ///
    /// - Returns: `false` when the surface has no live runtime, the export
    ///   fails, or the mode is off.
    @MainActor
    public func isBracketedPasteActive() -> Bool {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "bracketedPasteRead") else {
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
        guard let modes = try? JSONDecoder().decode(RenderGridModes.self, from: data) else { return false }
        return modes.modes.contains { $0.code == 2004 && !$0.ansi && $0.on }
    }
}

/// The `modes` field of the render-grid export.
private struct RenderGridModes: Decodable {
    struct Mode: Decodable {
        let code: Int
        let ansi: Bool
        let on: Bool
    }

    let modes: [Mode]
}
