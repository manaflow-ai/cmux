public import Foundation
public import GhosttyKit
public import CMUXMobileCore
import CmuxTerminalCore

// MARK: - Paired-iPhone (mobile) input and grid export

extension TerminalSurface {
    /// Forward a mobile scroll gesture to this real surface. libghostty does the
    /// mode-correct thing: a normal screen moves the viewport into scrollback;
    /// an alt screen with mouse reporting encodes mouse-wheel to the PTY for the
    /// program (vim/less/htop). `col`/`row` is the grid cell under the finger so
    /// the alt-screen wheel reports at the right cell. Runs on the main actor
    /// like the desktop's own scroll path.
    @MainActor
    public func mobileScroll(deltaLines: Double, col: Int, row: Int) {
        guard deltaLines != 0,
              let surface = liveSurfaceForGhosttyAccess(reason: "mobileScroll") else { return }
        let size = ghostty_surface_size(surface)
        // The surface is sized in backing pixels; `ghostty_surface_mouse_pos`
        // wants points, so divide the cell size by the content scale.
        let scale = max(Double(lastXScale), 1)
        let cellWidthPt = Double(size.cell_width_px) / scale
        let cellHeightPt = Double(size.cell_height_px) / scale
        let posX = (Double(col) + 0.5) * cellWidthPt
        let posY = (Double(row) + 0.5) * cellHeightPt
        ghostty_surface_mouse_pos(surface, posX, posY, GHOSTTY_MODS_NONE)
        ghostty_surface_mouse_scroll(surface, 0, deltaLines, 0)
    }

    /// Forward a mobile tap to this real surface as a left mouse click at the
    /// given grid cell. libghostty does the mode-correct thing: a program with
    /// mouse reporting (alt-screen TUIs like lazygit/htop/fzf) gets an encoded
    /// click report to its PTY; a normal screen treats it as an empty selection,
    /// which is harmless. `col`/`row` is the grid cell under the finger. Runs on
    /// the main actor like the desktop's own click path.
    @MainActor
    public func mobileClick(col: Int, row: Int) {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "mobileClick") else { return }
        let size = ghostty_surface_size(surface)
        // The surface is sized in backing pixels; `ghostty_surface_mouse_pos`
        // wants points, so divide the cell size by the content scale. Aim at the
        // cell center so the click lands unambiguously inside the target cell.
        let scale = max(Double(lastXScale), 1)
        let cellWidthPt = Double(size.cell_width_px) / scale
        let cellHeightPt = Double(size.cell_height_px) / scale
        let posX = (Double(max(0, col)) + 0.5) * cellWidthPt
        let posY = (Double(max(0, row)) + 0.5) * cellHeightPt
        ghostty_surface_mouse_pos(surface, posX, posY, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
    }

    /// Exports the surface grid as a mobile render frame (optionally filtered
    /// to changed rows).
    ///
    /// `inheritedTheme` is the Mac's resolved Ghostty theme (palette + default
    /// colors) to stamp onto a full snapshot so the phone inherits it. Resolving
    /// it walks the parsed config and formats colors, which is too expensive for
    /// the per-keystroke path, so the caller resolves it once (see
    /// ``resolvedTerminalTheme()``) and caches it across renders, recomputing
    /// only when the Ghostty config reloads. It is stamped only on a full frame
    /// (`filteredRows(full:)` drops the theme fields for deltas), so a delta
    /// export ignores it.
    @MainActor
    public func mobileRenderGridFrame(
        stateSeq: UInt64,
        full: Bool = true,
        changedRows: Set<Int>? = nil,
        scrollbackLines: Int = 0,
        inheritedTheme: MobileInheritedTerminalTheme? = nil
    ) -> (frame: MobileTerminalRenderGridFrame, rows: [String])? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "mobileRenderGrid") else { return nil }
        let surfaceID = id.uuidString
        let exported = surfaceID.withCString { ptr in
            ghostty_surface_render_grid_json(
                surface,
                ptr,
                UInt(surfaceID.utf8.count),
                stateSeq,
                UInt(max(0, scrollbackLines))
            )
        }
        defer { ghostty_string_free(exported) }
        guard let ptr = exported.ptr, exported.len > 0 else { return nil }

        let data = Data(bytes: ptr, count: Int(exported.len))
        guard var fullFrame = try? JSONDecoder().decode(MobileTerminalRenderGridFrame.self, from: data) else {
            return nil
        }
        // Stamp the Mac's resolved Ghostty theme (16-color ANSI palette + default
        // fg/bg/cursor) so the phone's local libghostty inherits it instead of
        // hardcoding Monokai. libghostty's grid JSON carries only the *dynamic*
        // default colors (OSC 10/11/12 a program set at runtime), not the
        // configured theme, and never the palette. Only a full snapshot keeps it
        // (`filteredRows(full:)` nils it for deltas), so skip the work on a delta
        // export — deltas run per keystroke. The caller passes a cached theme so
        // this is a plain assignment, not a config read, on the hot path.
        if full, let inheritedTheme {
            fullFrame.applyInheritedTheme(inheritedTheme)
        }
        let frame: MobileTerminalRenderGridFrame
        if full, changedRows == nil {
            frame = fullFrame
        } else {
            let includedRows = changedRows ?? Set(0..<fullFrame.rows)
            guard let filtered = try? fullFrame.filteredRows(includedRows, full: full) else {
                return nil
            }
            frame = filtered
        }
        return (frame, frame.plainRows())
    }

    /// The Mac's resolved Ghostty terminal theme: the full 16-color ANSI palette
    /// (`#RRGGBB`, indices 0...15) plus the default foreground/background/cursor
    /// colors, read from the same parsed config the Mac renders with
    /// (``GhosttyConfig/load()``). The palette is `nil` unless all 16 entries
    /// resolved, so a partial palette never replaces the phone's consistent
    /// built-in fallback. The fg/bg/cursor are `nil` when the user has not set
    /// them, so the phone keeps its own default for an unset color.
    ///
    /// This walks the parsed config and formats several NSColors, so callers must
    /// cache the result and recompute only when the Ghostty config reloads,
    /// rather than calling it on the per-keystroke render path.
    ///
    /// libghostty's C config getter cannot return the palette array (it returns
    /// `false` for a repeatable/array-shaped key), so this reads the parsed Swift
    /// config directly, mirroring how the Mac itself resolves these colors.
    public static func resolvedTerminalTheme() -> MobileInheritedTerminalTheme {
        let config = GhosttyConfig.load()
        let palette: [String]?
        if (0...15).allSatisfy({ config.palette[$0] != nil }) {
            palette = (0...15).map { config.palette[$0]!.hexString() }
        } else {
            palette = nil
        }
        return MobileInheritedTerminalTheme(
            palette: palette,
            foreground: config.hasParsedForegroundColor ? config.foregroundColor.hexString() : nil,
            background: config.hasParsedBackgroundColor ? config.backgroundColor.hexString() : nil,
            cursor: config.hasParsedCursorColor ? config.cursorColor.hexString() : nil
        )
    }
}
