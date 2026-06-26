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

    /// Installs the window-level Finder file-drop overlay. The installer body and
    /// AppKit positioning algorithm live in `CmuxWorkspaces.FileDropOverlayInstaller`;
    /// this witness provides the app-target overlay/chrome/`TabManager` steps.
    @discardableResult
    static func installFileDropOverlay(on window: NSWindow, tabManager: TabManager) -> Bool {
        FileDropOverlayInstaller(target: AppFileDropTarget())
            .installFileDropOverlay(on: window, tabManager: tabManager)
    }

    /// Retries `installFileDropOverlay(on:tabManager:)` until the window's content
    /// overlay target is ready, bounded by `remainingAttempts`.
    static func installFileDropOverlayWhenReady(
        on window: NSWindow,
        tabManager: TabManager,
        remainingAttempts: Int = 16
    ) {
        FileDropOverlayInstaller(target: AppFileDropTarget())
            .installFileDropOverlayWhenReady(
                on: window,
                tabManager: tabManager,
                remainingAttempts: remainingAttempts
            )
    }
}

// Thin app-side shim so `AppDelegate.createMainWindow(...)` keeps resolving its
// bare `installFileDropOverlay(on:tabManager:)` call after the free function was
// folded onto `AppFileDropTarget` (no-free-functions convention, CONVENTIONS s3).
// AppDelegate is a forbidden god file for this slice, so its call site cannot be
// rewritten here; this forwarder is the sanctioned thin shim it can call.
// TODO(refactor): when AppDelegate is next edited, replace its call with
// `AppFileDropTarget.installFileDropOverlay(on:tabManager:)` and delete this shim.
@discardableResult
@MainActor
func installFileDropOverlay(on window: NSWindow, tabManager: TabManager) -> Bool {
    AppFileDropTarget.installFileDropOverlay(on: window, tabManager: tabManager)
}
