import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation

/// The `surface.pip` witness of the surface-domain socket conformance. Split
/// out of `TerminalController+ControlSurfaceContext3` to keep that file under
/// the length budget; see `TerminalController+ControlSurfaceContext` for the
/// conformance overview.
extension TerminalController {

    func controlSurfacePip(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        actionRawValue: String
    ) -> ControlSurfacePipResolution {
        guard let action = AppDelegate.SurfacePipAction(rawValue: actionRawValue),
              let app = AppDelegate.shared else {
            return .failed
        }
        if surfaceID == nil, routing.hasWindowIDParam, routing.windowID == nil {
            return .surfaceNotFound
        }
        let routedTabManager = resolveTabManager(routing: routing)
        let resolvedSurfaceID: UUID?
        if let surfaceID {
            resolvedSurfaceID = surfaceID
        } else if action == .pop {
            guard let focusedPanelId = routedTabManager?.selectedWorkspace?.focusedPanelId else {
                return .surfaceNotFound
            }
            resolvedSurfaceID = focusedPanelId
        } else {
            resolvedSurfaceID = nil
        }
        switch app.performSurfacePipAction(panelId: resolvedSurfaceID, action: action, tabManager: routedTabManager) {
        case .success(let state):
            return .changed(
                surfaceID: state.panelId,
                isInPictureInPicture: state.isInPictureInPicture
            )
        case .failure(.surfaceNotFound):
            return .surfaceNotFound
        case .failure(.unsupportedSurfaceType):
            return .unsupportedSurfaceType
        case .failure(.notInPictureInPicture):
            return .notInPictureInPicture
        case .failure(.actionFailed):
            return .failed
        }
    }
}
