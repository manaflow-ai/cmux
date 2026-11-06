internal import CmuxAgentChat
internal import CmuxMobileRPC
internal import Foundation
public import CmuxMobileShellModel

extension MobileShellComposite {
    /// Loads complete recent bang commands from the Claude session bound to the captured terminal.
    public func loadSuggestedTerminalCommands(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async throws -> [TerminalCommandSuggestion] {
        guard let client = suggestedCommandsClient(workspaceID: workspaceID, terminalID: terminalID) else {
            throw TerminalCommandSuggestionsError.unavailable
        }
        let source = MobileChatEventSource(client: client)
        let loader = TerminalCommandSuggestionsLoader(
            sessions: { try await source.sessions(workspaceID: $0) },
            history: { try await source.history(sessionID: $0, beforeSeq: $1, limit: 100) }
        )
        let commands = try await loader.load(
            workspaceID: remoteWorkspaceID(for: workspaceID).rawValue,
            terminalID: terminalID.rawValue
        )
        try Task.checkCancellation()
        guard suggestedCommandsClient(workspaceID: workspaceID, terminalID: terminalID) === client else {
            throw TerminalCommandSuggestionsError.sessionChanged
        }
        return commands
    }

    /// Sends an explicitly reviewed command as one paste and one submit to its original Claude terminal.
    /// A changed session or connection is rejected without sending any input.
    @discardableResult
    public func runSuggestedTerminalCommand(
        _ suggestion: TerminalCommandSuggestion,
        editedText: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async -> Bool {
        guard !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let client = suggestedCommandsClient(workspaceID: workspaceID, terminalID: terminalID) else { return false }
        do {
            let session = try await MobileChatEventSource(client: client).session(sessionID: suggestion.sessionID)
            try Task.checkCancellation()
            guard session.id == suggestion.sessionID,
                  session.agentKind == .claude, session.kind == .agent, session.state != .ended,
                  TerminalCommandSuggestionsLoader.matches(session.workspaceID, remoteWorkspaceID(for: workspaceID).rawValue),
                  TerminalCommandSuggestionsLoader.matches(session.terminalID, terminalID.rawValue),
                  suggestedCommandsClient(workspaceID: workspaceID, terminalID: terminalID) === client else { return false }
            return await sendTerminalPaste(editedText, workspaceID: workspaceID, terminalID: terminalID)
        } catch {
            return false
        }
    }

    private func suggestedCommandsClient(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) -> MobileCoreRPCClient? {
        guard isSignedIn, workspace(workspaceID, containsSurfaceID: terminalID.rawValue) else { return nil }
        let target = workspaceMutationTarget(for: workspaceID)
        // The current paste owner is foreground-only; never fall back to another Mac.
        guard target.isForeground else { return nil }
        return target.client
    }
}
