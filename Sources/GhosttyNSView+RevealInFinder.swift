import AppKit
import CmuxTerminalCore
import GhosttyKit

extension GhosttyNSView {
    /// Adds "Reveal in Finder" when the selection, the hovered link, or the
    /// word under the pointer names an existing local file.
    ///
    /// Candidates resolve through ``TerminalPathResolver`` against the
    /// surface's working directory, the same way cmd-click resolves paths.
    /// Remote terminals are skipped so a path on another host never reveals
    /// an unrelated file on this Mac.
    ///
    /// - Parameters:
    ///   - menu: The context menu being built.
    ///   - surface: The live Ghostty surface.
    ///   - pointerLocation: The right-click point in view coordinates, or
    ///     `nil` when the menu was opened from pane chrome outside the
    ///     terminal viewport.
    func addRevealInFinderMenuItem(
        to menu: NSMenu,
        surface: ghostty_surface_t,
        pointerLocation: NSPoint?
    ) {
        guard let path = revealInFinderPath(surface: surface, pointerLocation: pointerLocation) else {
            return
        }
        let item = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.revealInFinder", defaultValue: "Reveal in Finder"),
            action: #selector(revealContextMenuPathInFinder(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = path
        item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    }

    /// Selects the menu item's resolved file in Finder.
    @objc func revealContextMenuPathInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func revealInFinderPath(surface: ghostty_surface_t, pointerLocation: NSPoint?) -> String? {
        guard let terminalSurface,
              let workspace = terminalSurface.owningWorkspace(),
              workspace.canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: terminalSurface.id) else {
            return nil
        }
        let cwd = CommandClickFileOpenRouter.resolveWorkingDirectory(
            workspace: workspace,
            surfaceId: terminalSurface.id
        )
        let selection = readSelectionSnapshot(surface: surface)?.string
        let hoveredLink = pointerLocation == nil
            ? nil
            : terminalSurface.hostedView.linkHoverIndicatorView.url
        if let path = TerminalPathResolver().resolveRevealPath(
            candidates: [selection, hoveredLink],
            cwd: cwd
        ) {
            return path
        }
        guard let pointerLocation else { return nil }
        return resolveWordUnderCursorAsPath(at: pointerLocation)
    }
}
