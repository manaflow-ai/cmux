public import AppKit

/// Installs and maintains the window-level file-drop overlay that intercepts
/// Finder file/URL drags above the entire content hierarchy. Owns the generic
/// AppKit algorithm only: resolve the installation target, find or create the
/// overlay, attach it with edge-pinned constraints, verify the attachment, and
/// retry on the next main-loop turn until the theme frame is ready. Every step
/// that names an app-target type, touches the per-window associated-object
/// storage, or reaches into the live `TabManager`/`Workspace` inverts through
/// ``FileDropTarget``.
///
/// Constructed once at the composition root with the app-side ``FileDropTarget``
/// conformer; `ContentView`/`AppDelegate` forward their one-line
/// `installFileDropOverlay(on:tabManager:)` and
/// `installFileDropOverlayWhenReady(on:tabManager:)` calls here.
@MainActor
public final class FileDropOverlayInstaller {
    private let target: any FileDropTarget

    /// Creates the installer over the app-side overlay seam.
    public init(target: any FileDropTarget) {
        self.target = target
    }

    /// Installs (or re-attaches) the overlay on the window for the given live
    /// `tabManager`. Returns `false` when the window's theme frame is not yet
    /// ready, so callers can retry.
    @discardableResult
    public func installFileDropOverlay(on window: NSWindow, tabManager: AnyObject) -> Bool {
        guard let target = self.target.contentOverlayInstallationTarget(for: window) else {
            return false
        }

        if let existingOverlay = self.target.existingOverlayView(on: window, in: target.container) {
            self.target.reconfigureOverlayView(existingOverlay, tabManager: tabManager)
            self.target.publishOverlayView(existingOverlay, on: window)
            guard !fileDropOverlay(
                existingOverlay,
                isAttachedTo: target.reference,
                in: target.container
            ) else {
                return true
            }
            existingOverlay.removeFromSuperview()
            attachFileDropOverlay(existingOverlay, to: target.reference, in: target.container)
            return true
        }

        let overlay = self.target.makeConfiguredOverlayView(
            frame: target.reference.frame,
            tabManager: tabManager
        )
        // Publish the overlay before mutating the view tree so any re-entrant lookup resolves
        // the in-flight view instead of installing a second overlay during layout.
        self.target.publishOverlayView(overlay, on: window)
        attachFileDropOverlay(overlay, to: target.reference, in: target.container)
        return true
    }

    /// Installs the overlay, retrying on the next main-loop turn (up to
    /// `remainingAttempts` times) when the theme frame is not yet ready.
    public func installFileDropOverlayWhenReady(
        on window: NSWindow,
        tabManager: AnyObject,
        remainingAttempts: Int = 16
    ) {
        guard !installFileDropOverlay(on: window, tabManager: tabManager),
              remainingAttempts > 0 else { return }

        // Defer retrying until the next main-loop turn so we don't mutate the
        // NSThemeFrame hierarchy while SwiftUI/AppKit is still attaching views.
        // `self` is captured strongly so the in-flight retry chain stays alive
        // (the legacy free function was never deallocated); the chain ends when
        // either weakly-held collaborator is gone or attempts run out, matching
        // the original `[weak window, weak tabManager]` guard exactly.
        DispatchQueue.main.async { [self, weak window, weak tabManager] in
            guard let window, let tabManager else { return }
            self.installFileDropOverlayWhenReady(
                on: window,
                tabManager: tabManager,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    private func attachFileDropOverlay(
        _ overlay: NSView,
        to referenceView: NSView,
        in containerView: NSView
    ) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(overlay, positioned: .above, relativeTo: referenceView)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: referenceView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: referenceView.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: referenceView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: referenceView.trailingAnchor)
        ])
    }

    private func fileDropOverlay(
        _ overlay: NSView,
        isAttachedTo referenceView: NSView,
        in containerView: NSView
    ) -> Bool {
        guard overlay.superview === containerView else { return false }
        let requiredAttributes: [NSLayoutConstraint.Attribute] = [.top, .bottom, .leading, .trailing]
        return requiredAttributes.allSatisfy { attribute in
            containerView.constraints.contains { constraint in
                let firstView = constraint.firstItem as? NSView
                let secondView = constraint.secondItem as? NSView
                return firstView === overlay &&
                    secondView === referenceView &&
                    constraint.firstAttribute == attribute &&
                    constraint.secondAttribute == attribute
            }
        }
    }
}
