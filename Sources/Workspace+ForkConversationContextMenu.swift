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

        guard var selection = agentConversationForkSelection(
            forPanelId: panelId,
            request: request
        ) else {
            return false
        }
        var snapshot = selection.snapshot
        let isRemoteContext = isRemoteTerminalSurface(panelId)
        if selection.requiresNativeForkCapability,
           AgentForkSupport.requiresForkValidationExecutableIdentity(
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
            guard let refreshedSelection = agentConversationForkSelection(
                forPanelId: panelId,
                request: request
            ) else {
                return false
            }
            guard refreshedSelection.requiresNativeForkCapability,
                  ContentView.commandPaletteForkSnapshotFingerprint(
                      refreshedSelection.snapshot,
                      isRemoteTerminal: isRemoteContext
                  ) == selectedSnapshotFingerprint,
                  AgentForkSupport.forkValidationIdentity(
                      snapshot: refreshedSelection.snapshot,
                      isRemoteContext: isRemoteContext
                  ) == selectedValidationIdentity else {
                return false
            }
            selection = refreshedSelection
            snapshot = refreshedSelection.snapshot
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
            request: request
        )
    }
}
