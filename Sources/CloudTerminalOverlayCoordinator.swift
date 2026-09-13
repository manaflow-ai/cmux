import AppKit
import CmuxTerminal
import os

private let cloudTerminalPresentationLogger = Logger(
    subsystem: "com.cmuxterm.app", category: "CloudTerminalPresentation"
)

/// Owns one status card across the representable anchor and the native portal.
/// The attachment session owns connection health. Layout and visibility only
/// choose where to present that state, never whether the connection has failed.
@MainActor
final class CloudTerminalOverlayCoordinator {
    private let dismissalStore: CloudBannerDismissalStore
    weak var session: CloudTuiManualMirrorSession?
    private(set) var overlay: CloudTerminalReconnectOverlayView?
    private weak var anchor: GhosttyTerminalView.HostContainerView?
    private var anchorOwnership: (generation: UInt64, serial: UInt64)?
    private var anchorVisible = false
    private var lastDestination: Destination = .hidden

    private enum Destination: String {
        case hidden, anchor, terminal
    }

    /// Creates a coordinator with an injected dismissal store.
    ///
    /// - Parameter dismissalStore: Repository shared by this native surface owner.
    init(dismissalStore: CloudBannerDismissalStore) {
        self.dismissalStore = dismissalStore
    }

    /// Creates a coordinator backed by the app's standard user defaults.
    convenience init() {
        self.init(dismissalStore: CloudBannerDismissalStore(defaults: .standard))
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

    /// Reconciles the current connection card with portal visibility and dismissal state.
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
        let presentation: CloudTerminalReconnectOverlayPolicy.Presentation?
        if let session {
            presentation = session.connectionPresentation
        } else {
            presentation = legacyPresentation
        }

        let destination: NSView = presented ? hostedView : ((anchor as NSView?) ?? hostedView)
        let dismissalID = hostedView.surfaceView.terminalSurface.map {
            "cloud.remote-reconnect.\($0.id.uuidString)"
        }
        apply(
            visible ? presentation : nil,
            in: destination,
            frame: presented ? contentFrame : destination.bounds,
            dismissalID: dismissalID,
            onReconnect: onReconnect
        )
        let next: Destination = overlay == nil ? .hidden : (presented ? .terminal : .anchor)
        if next != lastDestination, let session {
            cloudTerminalPresentationLogger.notice("pane terminal=\(session.terminalID, privacy: .private(mask: .hash)) destination=\(next.rawValue, privacy: .public) bound=\(presented) phase=\(String(describing: session.phase), privacy: .public)")
        }
        lastDestination = next
    }

    /// A retired session cannot clear a replacement session's presentation.
    func unbindSession(_ expectedSession: CloudTuiManualMirrorSession) {
        guard session === expectedSession else { return }
        session = nil
        overlay?.removeFromSuperview()
        overlay = nil
    }

    /// Applies a snapshot by moving the existing card; no second fallback view
    /// can retain a stale button or outlive a connected presentation.
    /// Places or removes a card for one presentation snapshot.
    func apply(
        _ presentation: CloudTerminalReconnectOverlayPolicy.Presentation?,
        in destination: NSView,
        frame: CGRect,
        dismissalID: String? = nil,
        onReconnect: @escaping () -> Void
    ) {
        guard let presentation else {
            overlay?.removeFromSuperview()
            overlay = nil
            return
        }
        let card = overlay ?? CloudTerminalReconnectOverlayView(frame: frame)
        if let dismissalID,
           dismissalStore.isDismissed(id: dismissalID, signature: presentation.copyableError) {
            card.removeFromSuperview()
            if overlay === card {
                overlay = nil
            }
            return
        }
        overlay = card
        card.apply(presentation)
        card.onReconnect = onReconnect
        card.onDismiss = { [weak self, weak card] in
            guard let self, let card, let dismissalID else { return }
            self.dismissalStore.dismiss(id: dismissalID, signature: presentation.copyableError)
            if self.overlay === card {
                card.removeFromSuperview()
                self.overlay = nil
            }
        }
        if card.frame != frame { card.frame = frame }
        card.autoresizingMask = [.width, .height]
        if card.superview !== destination {
            destination.addSubview(card, positioned: .above, relativeTo: nil)
        }
    }

}
