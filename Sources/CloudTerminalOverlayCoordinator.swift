import AppKit
import CmuxTerminal
import CmuxTerminalCore
import os

private let cloudTerminalPresentationLogger = Logger(
    subsystem: "com.cmuxterm.app", category: "CloudTerminalPresentation"
)

/// Owns one status card across the representable anchor and the native portal.
/// Session, layout, visibility, and rendered-frame events all reconcile this owner.
@MainActor
final class CloudTerminalOverlayCoordinator {
    weak var session: CloudTuiManualMirrorSession?
    private(set) var overlay: CloudTerminalReconnectOverlayView?
    private weak var anchor: GhosttyTerminalView.HostContainerView?
    private var anchorOwnership: (generation: UInt64, serial: UInt64)?
    private var anchorVisible = false
    private var renderDemand: (any RenderDemandRetention)?
    private var onRenderedFrame: (() -> Void)?
    private var lastDestination: Destination = .hidden

    private enum Destination: String {
        case hidden, anchor, terminal
    }

    /// A replaced representable may still emit layout and hide callbacks. Only
    /// the newest ownership epoch/host may move or hide this terminal's card.
    func updateAnchor(
        _ host: GhosttyTerminalView.HostContainerView,
        visible: Bool,
        ownershipGeneration: UInt64
    ) {
        let incoming = (generation: ownershipGeneration, serial: host.instanceSerial)
        if let current = anchorOwnership,
           incoming.generation < current.generation ||
            (incoming.generation == current.generation && incoming.serial < current.serial) {
            return
        }
        anchor = host
        anchorOwnership = incoming
        anchorVisible = visible
    }

    func synchronize(
        hostedView: GhosttySurfaceScrollView,
        contentFrame: CGRect,
        legacyPresentation: CloudTerminalReconnectOverlayPolicy.Presentation?,
        onReconnect: @escaping () -> Void
    ) {
        let visible = anchor == nil ? hostedView.isVisibleInUI : anchorVisible
        let presented: Bool
        if let anchor {
            presented = TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: anchor)
                && TerminalWindowPortalRegistry.isPresented(hostedView)
        } else {
            // Canvas can host the native view directly without a window portal.
            presented = hostedView.window != nil && !hostedView.isHidden
                && hostedView.bounds.width > 1 && hostedView.bounds.height > 1
        }
        let rendererReady = presented
            && hostedView.surfaceView.terminalSurface?.isRendererPresented == true
            && hostedView.surfaceView.renderedFrameSequence > 0
        var presentation: CloudTerminalReconnectOverlayPolicy.Presentation?
        if let session {
            presentation = session.connectionPresentation
            if session.phase != .stopped, presentation == nil, !rendererReady {
                presentation = unavailablePresentation
            }
        } else {
            presentation = legacyPresentation
        }
        let needsFrame = visible && session != nil && session?.phase != .stopped && !rendererReady
        if needsFrame, renderDemand == nil {
            renderDemand = hostedView.surfaceView.localRenderedFrameNotificationDemand.retain()
            onRenderedFrame = { [weak hostedView] in
                hostedView?.synchronizeCloudTerminalReconnectOverlay()
            }
        } else if !needsFrame {
            renderDemand?.release()
            renderDemand = nil
            onRenderedFrame = nil
        }

        let destination: NSView = presented ? hostedView : ((anchor as NSView?) ?? hostedView)
        apply(
            visible ? presentation : nil,
            in: destination,
            frame: presented ? contentFrame : destination.bounds,
            onReconnect: onReconnect
        )
        let next: Destination = overlay == nil ? .hidden : (presented ? .terminal : .anchor)
        if next != lastDestination, let session {
            cloudTerminalPresentationLogger.notice("pane terminal=\(session.terminalID, privacy: .private(mask: .hash)) destination=\(next.rawValue, privacy: .public) bound=\(presented) rendererReady=\(rendererReady)")
        }
        lastDestination = next
    }

    /// A retired session cannot clear a replacement session's presentation.
    func unbindSession(_ expectedSession: CloudTuiManualMirrorSession) {
        guard session === expectedSession else { return }
        session = nil
        overlay?.removeFromSuperview()
        overlay = nil
        renderDemand?.release()
        renderDemand = nil
        onRenderedFrame = nil
    }

    func renderedFrameArrived() {
        onRenderedFrame?()
    }

    /// Applies a snapshot by moving the existing card; no second fallback view
    /// can retain a stale button or outlive a connected presentation.
    func apply(
        _ presentation: CloudTerminalReconnectOverlayPolicy.Presentation?,
        in destination: NSView,
        frame: CGRect,
        onReconnect: @escaping () -> Void
    ) {
        guard let presentation else {
            overlay?.removeFromSuperview()
            overlay = nil
            return
        }
        let card = overlay ?? CloudTerminalReconnectOverlayView(frame: frame)
        overlay = card
        card.apply(presentation)
        card.onReconnect = onReconnect
        if card.frame != frame { card.frame = frame }
        card.autoresizingMask = [.width, .height]
        if card.superview !== destination {
            destination.addSubview(card, positioned: .above, relativeTo: nil)
        }
    }

    private var unavailablePresentation: CloudTerminalReconnectOverlayPolicy.Presentation {
        .init(
            title: String(localized: "cloud.overlay.manual.unavailable.title", defaultValue: "Cloud terminal unavailable"),
            detail: String(localized: "cloud.overlay.manual.unavailable.detail", defaultValue: "The terminal view is unavailable. Reconnect to restore it."),
            showsProgress: false,
            showsReconnectButton: true
        )
    }

    deinit {
        renderDemand?.release()
    }
}
