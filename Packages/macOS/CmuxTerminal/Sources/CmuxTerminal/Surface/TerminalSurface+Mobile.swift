public import Foundation
public import GhosttyKit
public import CMUXMobileCore

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
        guard deltaLines != 0 else { return }
        didReceiveExplicitInput()
        guard let surface = liveSurfaceForGhosttyAccess(reason: "mobileScroll") else { return }
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
        didReceiveExplicitInput()
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
    /// to changed rows). Set `includeTheme` to `false` for ordinary live ticks
    /// after the caller has cached this surface's theme; replay and invalidation
    /// snapshots should retain the default complete theme payload.
    @MainActor
    public func mobileRenderGridFrame(
        stateSeq: UInt64,
        full: Bool = true,
        changedRows: Set<Int>? = nil,
        scrollbackLines: Int = 0,
        includeTheme: Bool = true
    ) -> (frame: MobileTerminalRenderGridFrame, rows: [String])? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "mobileRenderGrid") else { return nil }
        let surfaceID = id.uuidString
        let exported = surfaceID.withCString { ptr in
            ghostty_surface_render_grid_json_with_theme(
                surface,
                ptr,
                UInt(surfaceID.utf8.count),
                stateSeq,
                UInt(max(0, scrollbackLines)),
                includeTheme
            )
        }
        defer { ghostty_string_free(exported) }
        guard let ptr = exported.ptr, exported.len > 0 else { return nil }

        let data = Data(bytes: ptr, count: Int(exported.len))
        guard var fullFrame = try? JSONDecoder().decode(MobileTerminalRenderGridFrame.self, from: data) else {
            return nil
        }
        if fullFrame.modes.contains(where: { !$0.ansi && $0.code == 5 && $0.on }) {
            // Ghostty exports renderer-effective defaults. Keep the v1 outer
            // fields raw because older iOS clients replay DEC reverse separately.
            let foreground = fullFrame.terminalForeground
            fullFrame.terminalForeground = fullFrame.terminalBackground
            fullFrame.terminalBackground = foreground
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
}
