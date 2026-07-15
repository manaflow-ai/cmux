internal import CMUXMobileCore
internal import CmuxAgentChat
internal import CmuxMobilePairedMac
public import CmuxMobileShellModel
public import Foundation

extension MobileShellComposite {
    /// Attach to an advertised runtime and resolve its exact live workspace and agent session.
    ///
    /// Registry data is only a discovery hint. The workspace list and advertised
    /// agent-session identity are both revalidated against the authenticated Mac
    /// before this method creates the one-shot chat navigation intent.
    /// - Parameters:
    ///   - deviceID: Registry device that owns the session.
    ///   - instanceTag: Exact app instance that advertised the session.
    ///   - sessionID: Advertised live-session id.
    ///   - agentSessionID: Agent-session identity captured by the tapped registry row.
    /// - Returns: The current workspace row id, or `nil` when the advertisement is stale or attach fails.
    public func prepareRegistrySessionHandoff(
        deviceID: String,
        instanceTag: String,
        sessionID: String,
        agentSessionID: String?,
        ifStillCurrent: @escaping () -> Bool = { true }
    ) async -> MobileWorkspacePreview.ID? {
        func ownsAttempt() -> Bool {
            ifStillCurrent()
        }

        func canContinue() -> Bool {
            !Task.isCancelled && ownsAttempt()
        }

        guard canContinue() else { return nil }
        registrySessionHandoffNavigationRequest = nil
        guard canContinue(),
              let device = registryDevices.first(where: { $0.deviceId == deviceID }),
              let instance = device.instances.first(where: { $0.tag == instanceTag }),
              let session = instance.sessions.first(where: { $0.id == sessionID }),
              session.agentSessionID == agentSessionID else {
            return nil
        }
        let previousActive = pairedMacs.first(where: \.isActive)

        await connectToRegistryInstance(
            device: device,
            instance: instance,
            ifStillCurrent: canContinue,
            ifRollbackStillOwned: ownsAttempt
        )
        guard canContinue(),
              connectionState == .connected,
              connectedMacDeviceID == device.deviceId,
              activeMacInstanceTag == instance.tag else {
            await restorePreviousMacAfterInterruptedFlow(previousActive, ifStillCurrent: ownsAttempt)
            return nil
        }

        let authoritativeRefreshSucceeded = await refreshWorkspacesAuthoritatively()
        guard canContinue(),
              let workspaceID = Self.registryHandoffWorkspaceID(
                  workspaceID: session.workspaceID,
                  deviceID: device.deviceId,
                  workspaces: workspaces,
                  authoritativeRefreshSucceeded: authoritativeRefreshSucceeded
              ) else {
            await restorePreviousMacAfterInterruptedFlow(previousActive, ifStillCurrent: ownsAttempt)
            if canContinue() { await loadRegistryDevices() }
            return nil
        }

        var authoritativeAgentSessionID: String?
        var terminalID = session.terminalID
        if agentSessionID != nil {
            let authoritativeSessions = await chatSessions(workspaceID: session.workspaceID)
            guard canContinue(),
                  let authoritativeSession = Self.registryHandoffAgentSession(
                      advertisedSession: session,
                      authoritativeSessions: authoritativeSessions
                  ) else {
                await restorePreviousMacAfterInterruptedFlow(previousActive, ifStillCurrent: ownsAttempt)
                if canContinue() { await loadRegistryDevices() }
                return nil
            }
            guard canContinue() else {
                await restorePreviousMacAfterInterruptedFlow(previousActive, ifStillCurrent: ownsAttempt)
                return nil
            }
            rememberRegistryHandoffChatSessions(authoritativeSessions, workspaceID: workspaceID)
            authoritativeAgentSessionID = authoritativeSession.id
            terminalID = authoritativeSession.terminalID
        }

        guard canContinue() else {
            await restorePreviousMacAfterInterruptedFlow(previousActive, ifStillCurrent: ownsAttempt)
            return nil
        }
        if let terminalID,
           let workspace = workspaces.first(where: { $0.id == workspaceID }),
           let terminal = workspace.terminals.first(where: { $0.id.rawValue == terminalID }) {
            guard canContinue() else {
                await restorePreviousMacAfterInterruptedFlow(previousActive, ifStillCurrent: ownsAttempt)
                return nil
            }
            selectTerminal(terminal.id)
        } else if authoritativeAgentSessionID != nil {
            await restorePreviousMacAfterInterruptedFlow(previousActive, ifStillCurrent: ownsAttempt)
            if canContinue() { await loadRegistryDevices() }
            return nil
        }
        guard canContinue() else {
            await restorePreviousMacAfterInterruptedFlow(previousActive, ifStillCurrent: ownsAttempt)
            return nil
        }
        if let authoritativeAgentSessionID {
            registrySessionHandoffNavigationRequest = RegistrySessionHandoffNavigationRequest(
                token: UUID(),
                workspaceID: workspaceID,
                agentSessionID: authoritativeAgentSessionID
            )
        }
        return workspaceID
    }

    static func registryHandoffShouldRestorePreviousMac(
        hasPreviousActive: Bool,
        canContinue: Bool,
        stillOwnsAttempt: Bool
    ) -> Bool {
        hasPreviousActive && !canContinue && stillOwnsAttempt
    }

    /// Restore outside a cancelled caller so an interrupted destructive switch can still complete.
    func restorePreviousMacAfterInterruptedFlow(
        _ previousActive: MobilePairedMac?,
        ifStillCurrent: @escaping () -> Bool = { true }
    ) async {
        guard previousActive != nil, ifStillCurrent() else { return }
        let restoration = Task { @MainActor [weak self] in
            guard let self, ifStillCurrent() else { return false }
            return await self.restorePreviousMacIfNeeded(
                previousActive,
                ifStillCurrent: ifStillCurrent
            )
        }
        _ = await restoration.value
    }

    /// Resolve a registry's runtime-local workspace identity without crossing Mac ownership boundaries.
    static func registryHandoffWorkspaceID(
        workspaceID: String,
        deviceID: String,
        workspaces: [MobileWorkspacePreview],
        authoritativeRefreshSucceeded: Bool = true
    ) -> MobileWorkspacePreview.ID? {
        guard authoritativeRefreshSucceeded else { return nil }
        return workspaces.first { workspace in
            workspace.rpcWorkspaceID.rawValue == workspaceID
                && workspace.macDeviceID == deviceID
        }?.id
    }

    /// Match the exact advertised agent identity and its authoritative workspace/terminal binding.
    static func registryHandoffAgentSession(
        advertisedSession: CmxLiveSession,
        authoritativeSessions: [ChatSessionDescriptor]
    ) -> ChatSessionDescriptor? {
        guard let agentSessionID = advertisedSession.agentSessionID else { return nil }
        return authoritativeSessions.first { session in
            session.id == agentSessionID
                && session.workspaceID == advertisedSession.workspaceID
                && (advertisedSession.terminalID == nil
                    || session.terminalID == advertisedSession.terminalID)
        }
    }

    /// Cache authoritative handoff descriptors under the aggregate row identity used by workspace detail.
    func rememberRegistryHandoffChatSessions(
        _ sessions: [ChatSessionDescriptor],
        workspaceID: MobileWorkspacePreview.ID
    ) {
        rememberChatSessions(sessions, workspaceID: workspaceID.rawValue)
    }

    /// Consume the handoff chat intent only if the presented detail still owns its token.
    public func consumeRegistrySessionHandoffNavigationRequest(token: UUID) {
        guard registrySessionHandoffNavigationRequest?.token == token else { return }
        registrySessionHandoffNavigationRequest = nil
    }
}
