import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - File drop overlay installation
var fileDropOverlayKey: UInt8 = 0
/// Installs a FileDropOverlayView on the window's theme frame for Finder file drag support.
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

private func configureFileDropOverlay(_ overlay: FileDropOverlayView, tabManager: TabManager) {
    overlay.onDrop = { [weak tabManager] urls in
        MainActor.assumeIsolated {
            guard let tabManager, let terminal = tabManager.selectedWorkspace?.focusedTerminalPanel else { return false }
            return terminal.hostedView.handleDroppedURLs(urls)
        }
    }
}

private func attachFileDropOverlay(
    _ overlay: FileDropOverlayView,
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
    _ overlay: FileDropOverlayView,
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

@discardableResult
func installFileDropOverlay(on window: NSWindow, tabManager: TabManager) -> Bool {
    guard let target = windowContentOverlayInstallationTarget(for: window) else { return false }

    let existingOverlay =
        (objc_getAssociatedObject(window, &fileDropOverlayKey) as? FileDropOverlayView)
        ?? findFileDropOverlayView(in: target.container)

    if let existingOverlay {
        configureFileDropOverlay(existingOverlay, tabManager: tabManager)
        objc_setAssociatedObject(window, &fileDropOverlayKey, existingOverlay, .OBJC_ASSOCIATION_RETAIN)
        guard !fileDropOverlay(existingOverlay, isAttachedTo: target.reference, in: target.container) else {
            return true
        }
        existingOverlay.removeFromSuperview()
        attachFileDropOverlay(existingOverlay, to: target.reference, in: target.container)
        return true
    }

    let overlay = FileDropOverlayView(frame: target.reference.frame)
    configureFileDropOverlay(overlay, tabManager: tabManager)
    // Publish the overlay before mutating the view tree so any re-entrant lookup resolves
    // the in-flight view instead of installing a second overlay during layout.
    objc_setAssociatedObject(window, &fileDropOverlayKey, overlay, .OBJC_ASSOCIATION_RETAIN)
    attachFileDropOverlay(overlay, to: target.reference, in: target.container)
    return true
}

func installFileDropOverlayWhenReady(
    on window: NSWindow,
    tabManager: TabManager,
    remainingAttempts: Int = 16
) {
    guard !installFileDropOverlay(on: window, tabManager: tabManager),
          remainingAttempts > 0 else { return }

    // Defer retrying until the next main-loop turn so we don't mutate the
    // NSThemeFrame hierarchy while SwiftUI/AppKit is still attaching views.
    DispatchQueue.main.async { [weak window, weak tabManager] in
        guard let window, let tabManager else { return }
        installFileDropOverlayWhenReady(
            on: window,
            tabManager: tabManager,
            remainingAttempts: remainingAttempts - 1
        )
    }
}

