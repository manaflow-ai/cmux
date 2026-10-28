import Foundation

@MainActor
final class SurfaceResumeRunPromptBatch {
    static let shared = SurfaceResumeRunPromptBatch()

    enum StickyDecision {
        case runAll
        case skipAll
    }

    private(set) var stickyDecision: StickyDecision?
    private var activePassDepth = 0
    private var claimedAgentRestoreKeys: Set<String> = []
    private var ownedAgentRestoreKeysByPanelID: [UUID: String] = [:]

    private init() {}

    var effectiveDecision: StickyDecision? {
        activePassDepth > 0 ? stickyDecision : nil
    }

    /// Outcome of claiming automatic startup for one agent checkpoint.
    enum AgentRestoreClaim: Equatable {
        /// No restore pass is active, so the checkpoint is not tracked.
        case unscoped
        /// This panel owns automatic startup for the checkpoint.
        case owner
        /// Another panel already owns automatic startup for the checkpoint.
        case duplicate
    }

    /// Claims one agent checkpoint for the current restore pass. The first
    /// panel carrying a checkpoint owns automatic startup; every later panel
    /// with the same checkpoint is a duplicate.
    func claimAgentRestore(kind: String, sessionID: String) -> AgentRestoreClaim {
        guard activePassDepth > 0 else { return .unscoped }
        let key = agentRestoreKey(kind: kind, sessionID: sessionID)
        return claimedAgentRestoreKeys.insert(key).inserted ? .owner : .duplicate
    }

    /// Releases a claim this panel took as `.owner` when the panel could not
    /// be attached, so a later panel carrying the checkpoint may start it.
    func releaseAgentRestore(kind: String, sessionID: String) {
        guard activePassDepth > 0 else { return }
        claimedAgentRestoreKeys.remove(agentRestoreKey(kind: kind, sessionID: sessionID))
    }

    /// Associates an owned claim with the attached panel across container transfers.
    func recordAgentRestoreOwner(panelID: UUID, kind: String, sessionID: String) {
        guard activePassDepth > 0 else { return }
        ownedAgentRestoreKeysByPanelID[panelID] = agentRestoreKey(kind: kind, sessionID: sessionID)
    }

    /// Releases only the claim this panel owned when its destination rejected it.
    func releaseAgentRestore(panelID: UUID) {
        guard let key = ownedAgentRestoreKeysByPanelID.removeValue(forKey: panelID) else { return }
        claimedAgentRestoreKeys.remove(key)
    }

    /// Builds the canonical key shared by all representations of a checkpoint.
    private func agentRestoreKey(kind: String, sessionID: String) -> String {
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedKind + "\u{1f}" + ManagedAgentSessionIdentity.canonicalSessionID(
            kind: normalizedKind,
            sessionID: sessionID
        )
    }

    /// Starts a nested restore pass and retains claims from its enclosing pass.
    func beginRestorePass() {
        activePassDepth += 1
    }

    /// Ends a nested restore pass and clears claims when the outer pass ends.
    func endRestorePass() {
        activePassDepth -= 1
        if activePassDepth <= 0 {
            activePassDepth = 0
            stickyDecision = nil
            claimedAgentRestoreKeys.removeAll(keepingCapacity: false)
            ownedAgentRestoreKeysByPanelID.removeAll()
        }
    }

    /// Records the restore prompt decision for the active pass.
    func recordDecision(_ decision: StickyDecision) {
        guard activePassDepth > 0 else { return }
        stickyDecision = decision
    }

    /// Clears the prompt decision, claims, and ownership bookkeeping.
    func reset() {
        activePassDepth = 0
        claimedAgentRestoreKeys.removeAll(keepingCapacity: false)
        ownedAgentRestoreKeysByPanelID.removeAll()
        stickyDecision = nil
    }
}

extension SurfaceResumeRunPromptBatch {
    /// The checkpoint a restored panel is about to start, used to dedupe one
    /// restore pass: the structured agent snapshot when it may auto-resume,
    /// otherwise an agent-hook binding whose launch was resolved. Multiplexer
    /// bindings (tmux, herdr) are never keyed, because attaching one
    /// multiplexer session from several panes is normal.
    nonisolated static func agentRestoreIdentity(
        restorableAgent: SessionRestorableAgentSnapshot?,
        agentMayAutoResume: Bool,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        bindingWillLaunch: Bool
    ) -> (kind: String, sessionID: String)? {
        if agentMayAutoResume, let restorableAgent,
           Self.hasAgentRestoreIdentity(restorableAgent) {
            return (restorableAgent.kind.rawValue, restorableAgent.sessionId)
        }
        guard bindingWillLaunch,
              let resumeBinding,
              resumeBinding.isAgentHookBinding,
              let kind = Self.agentHookKind(resumeBinding),
              let checkpointID = resumeBinding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checkpointID.isEmpty else {
            return nil
        }
        return (kind, checkpointID)
    }

    /// Infers the legacy kind only when the command's executable is Codex.
    private nonisolated static func agentHookKind(_ binding: SurfaceResumeBindingSnapshot) -> String? {
        if let kind = binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines), !kind.isEmpty {
            return kind
        }
        // Legacy Codex hooks persisted before `kind` was added. Parse the
        // executable token rather than searching the whole command: a Claude
        // restore can legitimately have "codex" in its working directory.
        return Self.legacyAgentExecutable(in: binding.command) == "codex" ? "codex" : nil
    }

    /// Identity is independent of shell transport: --surface can resolve
    /// checkpoint paths and registered agents whose IDs need shell quoting.
    private nonisolated static func hasAgentRestoreIdentity(
        _ restorableAgent: SessionRestorableAgentSnapshot
    ) -> Bool {
        !restorableAgent.kind.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !restorableAgent.sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Uses the same quoted-word and cwd-guard parser as binding replay.
    private nonisolated static func legacyAgentExecutable(in command: String) -> String? {
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(command)
        guard let index = SurfaceResumeCommandCanonicalizer.commandExecutableWordIndex(
            in: words, command: command
        ) else { return nil }
        return (words[index].value as NSString).lastPathComponent
    }
}
