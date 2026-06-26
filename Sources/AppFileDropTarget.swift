import AppKit
import CmuxAppKitSupportUI
import CmuxWorkspaces
import ObjectiveC

/// App-target implementer of ``FileDropTarget`` for ``FileDropOverlayInstaller``.
/// Owns every step the package cannot perform: resolving the window
/// content-overlay target (`AppWindowChromeComposition`), finding/creating the
/// concrete `FileDropOverlayView`, wiring its drop handler to the live
/// `TabManager`/`Workspace`, and the per-window associated-object record under
/// `fileDropOverlayKey` (the same storage read by `TerminalWindowPortal` and
/// `TerminalController`). Stateless; constructed at the install call sites.
@MainActor
final class AppFileDropTarget: FileDropTarget {
    func contentOverlayInstallationTarget(
        for window: NSWindow
    ) -> (container: NSView, reference: NSView)? {
        guard let target = AppWindowChromeComposition()
            .contentOverlayTargetResolver
            .installationTarget(for: window) else { return nil }
        return (container: target.container, reference: target.reference)
    }

    func existingOverlayView(on window: NSWindow, in container: NSView) -> NSView? {
        (objc_getAssociatedObject(window, &fileDropOverlayKey) as? FileDropOverlayView)
            ?? findFileDropOverlayView(in: container)
    }

    func makeConfiguredOverlayView(frame: NSRect, tabManager: AnyObject) -> NSView {
        let overlay = FileDropOverlayView(frame: frame)
        configureFileDropOverlay(overlay, tabManager: tabManager as? TabManager)
        return overlay
    }

    func reconfigureOverlayView(_ overlay: NSView, tabManager: AnyObject) {
        guard let overlay = overlay as? FileDropOverlayView else { return }
        configureFileDropOverlay(overlay, tabManager: tabManager as? TabManager)
    }

    func publishOverlayView(_ overlay: NSView, on window: NSWindow) {
        objc_setAssociatedObject(window, &fileDropOverlayKey, overlay, .OBJC_ASSOCIATION_RETAIN)
    }

    /// Recursively searches `root` for the installed `FileDropOverlayView`.
    private func findFileDropOverlayView(in root: NSView?) -> FileDropOverlayView? {
        guard let root else { return nil }
        if let overlay = root as? FileDropOverlayView {
            return overlay
        }
        for subview in root.subviews {
            if let overlay = findFileDropOverlayView(in: subview) {
                return overlay
            }
        }
        return nil
    }

    /// Wires the overlay's fallback drop handler to the focused terminal of the
    /// given tab manager's selected workspace.
    private func configureFileDropOverlay(_ overlay: FileDropOverlayView, tabManager: TabManager?) {
        overlay.onDrop = { [weak tabManager] urls in
            MainActor.assumeIsolated {
                guard let tabManager, let terminal = tabManager.selectedWorkspace?.focusedTerminalPanel else { return false }
                return terminal.hostedView.handleDroppedURLs(urls)
            }
        }
    }
}
