import Bonsplit
import CmuxSettings
import Foundation

extension Workspace {
    @discardableResult
    func forkAgentConversationFromContextMenu(
        fromPanelId panelId: UUID,
        destination: AgentConversationForkDestination
    ) async -> Bool {
        await forkAgentConversationFromContextMenu(
            fromPanelId: panelId,
            request: AgentConversationForkRequest(
                targetHarness: .current,
                destination: destination
            )
        )
    }

    @discardableResult
    func forkAgentConversationFromContextMenu(
        fromPanelId panelId: UUID,
        request: AgentConversationForkRequest
    ) async -> Bool {
        guard beginForkAgentConversationAction(panelId: panelId) else {
            return false
        }
        defer {
            endForkAgentConversationAction(panelId: panelId)
        }

        var selection = forkAgentConversationContextMenuOpenSelection(
            forPanelId: panelId
        )
        guard var snapshot = selection.snapshot,
              var anchorTabId = surfaceIdFromPanelId(panelId),
              var paneId = paneId(forPanelId: panelId) else {
            return false
        }
        let isRemoteContext = isRemoteTerminalSurface(panelId)
        if AgentForkSupport.requiresForkValidationExecutableIdentity(
            snapshot: snapshot,
            isRemoteContext: isRemoteContext
        ) {
            let selectedSnapshotFingerprint = ContentView.commandPaletteForkSnapshotFingerprint(
                snapshot,
                isRemoteTerminal: isRemoteContext
            )
            let selectedValidationIdentity = AgentForkSupport.forkValidationIdentity(
                snapshot: snapshot,
                isRemoteContext: isRemoteContext
            )
            guard let cachedExecutableFingerprint = SharedLiveAgentIndex.shared.forkSupportProbeExecutableFingerprint(
                workspaceId: id,
                panelId: panelId,
                isRemoteContext: isRemoteContext,
                fallbackSnapshot: selection.validationFallbackSnapshot
            ) else {
                return false
            }
            let currentExecutableFingerprint = await SharedLiveAgentIndex.shared.forkValidationExecutableFingerprint(
                snapshot: snapshot,
                isRemoteContext: isRemoteContext
            )
            let refreshedSelection = forkAgentConversationContextMenuOpenSelection(
                forPanelId: panelId
            )
            guard refreshedSelection.availability.isAvailable,
                  let refreshedSnapshot = refreshedSelection.snapshot,
                  ContentView.commandPaletteForkSnapshotFingerprint(
                    refreshedSnapshot,
                    isRemoteTerminal: isRemoteContext
                  ) == selectedSnapshotFingerprint,
                  AgentForkSupport.forkValidationIdentity(
                    snapshot: refreshedSnapshot,
                    isRemoteContext: isRemoteContext
                  ) == selectedValidationIdentity,
                  let refreshedAnchorTabId = surfaceIdFromPanelId(panelId),
                  let refreshedPaneId = self.paneId(forPanelId: panelId) else {
                return false
            }
            selection = refreshedSelection
            snapshot = refreshedSnapshot
            anchorTabId = refreshedAnchorTabId
            paneId = refreshedPaneId
            guard currentExecutableFingerprint == cachedExecutableFingerprint,
                  SharedLiveAgentIndex.shared.forkSupportProbeAccepted(
                    workspaceId: id,
                    panelId: panelId,
                    isRemoteContext: isRemoteContext,
                    fallbackSnapshot: selection.validationFallbackSnapshot
                  ) else {
                return false
            }
        }

        return await forkAgentConversation(
            fromPanelId: panelId,
            snapshot: snapshot,
            request: request,
            anchorTabId: anchorTabId,
            paneId: paneId
        )
    }
}
