import CmuxCore
import Foundation

/// A restored pane has no local process or attachment yet. Its saved identity
/// still warrants a visible state, even when discovery cannot reach the machine.
struct CloudTerminalMaterializationPresentation {
    let machine: SurfaceMachineInfo?
    var identity: SurfaceProjectionRecord? = nil
    var graph: CloudVMState? = nil
    var graphIsCurrent = false

    private var isMissingView: Bool {
        guard graphIsCurrent, let tabID = identity?.remoteTabID else { return false }
        guard let tab = graph?.lookupIndex.tab(id: tabID) else { return true }
        return tab.contentKind != "terminal" || tab.contentID != identity?.resource.key
    }

    var presentation: CloudTerminalReconnectOverlayPolicy.Presentation? {
        let state: WorkspaceRemoteConnectionState
        let missingView = isMissingView
        switch missingView ? SurfaceLinkState.error : machine?.linkState {
        case .asleep: state = .disconnected
        case .error, .unavailable, .notApplicable: state = .error
        case .connected, .connecting, .none: state = .connecting
        }
        if state == .connecting {
            // Before discovery there is no session or reservation to drive the
            // normal connection policy. The saved pane still needs a visible state.
            return CloudTerminalReconnectOverlayPolicy.Presentation(
                title: String(localized: "cloud.overlay.reconnecting.title", defaultValue: "Reconnecting Cloud session"),
                detail: String(localized: "cloud.overlay.reconnecting.detail", defaultValue: "Waiting for a secure terminal endpoint."),
                showsProgress: true,
                showsReconnectButton: false
            )
        }
        return CloudTerminalReconnectOverlayPolicy.presentation(
            isManagedCloudWorkspace: true, isRemoteTerminalSurface: true,
            connectionState: state, detail: missingView ? CloudDiagnosticFailure.notFound.label : nil
        )
    }
}
