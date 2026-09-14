import CmuxTerminal
import CmuxRemoteSession
import Foundation

/// Starts a local Cloud mirror before remote discovery finishes.
@MainActor
extension CmuxTuiSurfaceProvider {
    /// Creates a native manual-I/O pane and lets the provider resolve its
    /// daemon-local surface asynchronously through the normal refresh owner.
    ///
    /// The pane is returned as soon as its local runtime exists, so a cold
    /// endpoint or a delayed workspace snapshot cannot leave the requested
    /// split blank. A zero surface id is intentionally not attachable; the
    /// attachment recovery pass replaces it after an authoritative resolve.
    func materializeManualMirrorTerminal(
        _ resource: SurfaceResource,
        remoteTabID: String? = nil,
        at destination: SurfaceDestination,
        focus: Bool
    ) async throws -> CloudManualMirrorMaterialization {
        let selectedRemoteView = remoteTabID.flatMap { tabID in
            resource.remoteViews?.first(where: { $0.tabID == tabID })
        }
        let initialPlacement = selectedRemoteView.map {
            SurfaceRemotePlacement(workspaceID: $0.workspace.id, tabID: $0.tabID)
        }
        let session = CloudTuiManualMirrorSession(
            machineID: machineID,
            terminalID: resource.id.key,
            remoteSurfaceID: 0,
            operations: links.operations,
            onNeedsReconnect: { [weak self] in
                self?.scheduleRefresh()
            }
        )
        let inputRouter = session.inputRouter
        var createdPanel: (workspaceID: UUID, panelID: UUID)?
        do {
            let created = try SurfacePaneFactory.makeCloudManualMirrorPane(
                at: destination,
                focus: focus,
                onInput: { input in inputRouter.send(input) },
                keyNameResolver: { RemoteTmuxKeyName(inputEvent: $0)?.value },
                onResize: { [weak session] sample in
                    session?.apply(size: sample)
                },
                onRuntimeReady: { [weak session] in
                    session?.runtimeReady()
                },
                onFocus: { [weak session] in
                    session?.claimGeometry()
                },
                attachment: session.attachmentStatus
            )
            createdPanel = (created.workspaceID, created.panelID)
            session.bind(surface: created.surface)
            let existingExplicitInput = created.surface.onExplicitInput
            created.surface.onExplicitInput = { [weak session] in
                existingExplicitInput?()
                session?.claimGeometry()
            }
            manualMirrorSessions[created.panelID] = session
            scheduleRefresh()
            return CloudManualMirrorMaterialization(
                workspaceID: created.workspaceID,
                panelID: created.panelID,
                surface: created.surface,
                session: session,
                remotePlacement: initialPlacement
            )
        } catch {
            if let createdPanel {
                manualMirrorSessions.removeValue(forKey: createdPanel.panelID)?.stop()
                SurfacePaneFactory.close(panelID: createdPanel.panelID, in: createdPanel.workspaceID)
            } else {
                session.stop()
            }
            throw error
        }
    }
}
