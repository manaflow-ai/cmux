public import AppKit
public import CmuxCore

/// Window-level controller that presents a workspace's tmux pane overlay above
/// the content hierarchy. Owns the generic AppKit lifecycle only: build a
/// passthrough container holding a SwiftUI hosting view, reparent it into the
/// window's resolved content-overlay target with edge-pinned constraints, and
/// show/hide + dedup it as render states arrive. Every step that names an
/// app-target or higher-package type (the container/hosting view construction,
/// the model update, the installation-target resolution) inverts through
/// ``TmuxWorkspacePaneOverlayTarget``.
///
/// One controller is created per window by ``TmuxWorkspacePaneOverlayRegistry``;
/// `ContentView`/`AppDelegate` forward their one-line `update(state:)` calls
/// through that registry. This is the byte-faithful lift of the former
/// app-target `WindowTmuxWorkspacePaneOverlayController` from
/// `ContentView.swift`.
@MainActor
public final class TmuxWorkspacePaneOverlayController {
    private weak var window: NSWindow?
    private let target: any TmuxWorkspacePaneOverlayTarget
    private let containerView: NSView
    private let hostingView: NSView
    private var installConstraints: [NSLayoutConstraint] = []
    private weak var installedReferenceView: NSView?
    private var lastRenderState: TmuxWorkspacePaneOverlayRenderState?

    /// Creates the controller for `window`, building the container and hosting
    /// view through `target` and installing them immediately.
    public init(window: NSWindow, target: any TmuxWorkspacePaneOverlayTarget) {
        self.window = window
        self.target = target
        self.containerView = target.makeOverlayContainerView()
        self.hostingView = target.makeOverlayHostingView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.isHidden = true
        containerView.alphaValue = 0
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])
        _ = ensureInstalled()
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window,
              let target = self.target.contentOverlayInstallationTarget(for: window) else { return false }

        if containerView.superview !== target.container || installedReferenceView !== target.reference {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()
            containerView.removeFromSuperview()
            target.container.addSubview(containerView, positioned: .above, relativeTo: target.reference)
            installConstraints = [
                containerView.topAnchor.constraint(equalTo: target.reference.topAnchor),
                containerView.bottomAnchor.constraint(equalTo: target.reference.bottomAnchor),
                containerView.leadingAnchor.constraint(equalTo: target.reference.leadingAnchor),
                containerView.trailingAnchor.constraint(equalTo: target.reference.trailingAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedReferenceView = target.reference
        }

        return true
    }

    /// Updates the overlay to reflect `state`, or hides it when `state` is `nil`.
    /// Deduplicates equal consecutive states and no-ops when already hidden with
    /// nothing to show.
    public func update(state: TmuxWorkspacePaneOverlayRenderState?) {
        guard ensureInstalled() else { return }

        if state == nil, lastRenderState == nil, containerView.isHidden {
            return
        }
        if let state, state == lastRenderState {
            return
        }

        if let state {
            lastRenderState = state
            target.applyRenderState(state, to: hostingView)
            containerView.alphaValue = 1
            containerView.isHidden = false
        } else {
            lastRenderState = nil
            target.clearRenderState(on: hostingView)
            containerView.alphaValue = 0
            containerView.isHidden = true
        }
    }
}
