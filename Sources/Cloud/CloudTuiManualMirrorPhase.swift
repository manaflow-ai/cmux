import AppKit
import CmuxCore
import CmuxTerminal
import os.log

/// Lifecycle of one cloud terminal's byte attachment.
enum CloudTuiManualMirrorPhase: Equatable, Sendable {
    case idle
    case connecting
    case attached
    case disconnected
    case stopped
}

/// Keeps a Cloud pane in an explicit state until both the replay and renderer are ready.
enum CloudTuiManualMirrorPresentationPolicy {
    static func connectionState(
        phase: CloudTuiManualMirrorPhase,
        replayReceived: Bool,
        rendererReady: Bool
    ) -> WorkspaceRemoteConnectionState? {
        switch phase {
        case .idle, .connecting: return .connecting
        case .attached:
            guard replayReceived else { return .connecting }
            return rendererReady ? .connected : .error
        case .disconnected: return .error
        case .stopped: return nil
        }
    }
}

enum CloudTuiManualMirrorLog {
    nonisolated private static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "CloudManualMirror"
    )

    static func bind(terminalID: String, remoteSurfaceID: UInt64) {
        logger.info(
            "bind terminal=\(terminalID, privacy: .private) remoteSurface=\(remoteSurfaceID)"
        )
    }

    static func phase(
        terminalID: String,
        remoteSurfaceID: UInt64,
        phase: CloudTuiManualMirrorPhase,
        replayReceived: Bool
    ) {
        logger.info(
            "phase terminal=\(terminalID, privacy: .private) remoteSurface=\(remoteSurfaceID) phase=\(String(describing: phase), privacy: .public) replay=\(replayReceived ? 1 : 0)"
        )
    }

    static func portalUnbound(surface: TerminalSurface) {
        logger.notice(
            "geometry terminal=\(surface.id.uuidString, privacy: .private) decision=portal-unbound rendererPresented=\(surface.isRendererPresented ? 1 : 0)"
        )
    }
}

extension GhosttyTerminalView.HostContainerView {
    @MainActor
    func synchronizeCloudManualMirrorFallback(
        hostedView: GhosttySurfaceScrollView,
        terminalSurface: TerminalSurface,
        visible: Bool
    ) {
        let portalBound = TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: self)
        let workspace = terminalSurface.owningWorkspace()
        let session = workspace?.cloudVMID.flatMap { machineID in
            CmuxTuiSurfaceProviderRegistry.shared.provider(machineID: machineID)?.manualMirrorSessions[terminalSurface.id]
        }
        let presentation = session?.connectionPresentation
        guard visible, !portalBound, let presentation else {
            cloudFallbackOverlay?.removeFromSuperview()
            cloudFallbackOverlay = nil
            return
        }
        if cloudFallbackOverlay == nil {
            CloudTuiManualMirrorLog.portalUnbound(surface: terminalSurface)
        }
        let overlay = cloudFallbackOverlay ?? CloudTerminalReconnectOverlayView(frame: bounds)
        cloudFallbackOverlay = overlay
        overlay.apply(presentation)
        overlay.onReconnect = { [weak terminalSurface] in
            guard let terminalSurface,
                  let workspace = terminalSurface.owningWorkspace() else { return }
            _ = workspace.reconnectCloudTerminalSurface(surfaceId: terminalSurface.id)
        }
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        if overlay.superview !== self {
            addSubview(overlay)
        }
    }
}
