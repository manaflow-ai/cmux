import CMUXAgentLaunch
import CmuxControlSocket
import Foundation

/// Provider evidence is scoped to the account the restoring CLI will actually exec.
struct AgentRestoreCodexEvidence {
    func inspect(
        record: ControlSurfaceRestoreRecord,
        sessionID: String,
        effectiveHome: String?
    ) -> CodexWriterLockInspection? {
        guard record.kind == "codex", record.modeRawValue == AgentRestoreRequestMode.resumeAgent.rawValue else {
            return nil
        }
        let arguments = record.preparedArguments ?? record.launchCommand?.arguments ?? []
        // Remote app-server ownership cannot be inferred from a local lock.
        if CodexRestoreAccount().usesRemoteProvider(arguments: arguments) {
            return nil
        }
        // Same-build CLI supplies the final invocation account. A legacy caller
        // without that evidence must continue using complete process evidence.
        guard let effectiveHome, effectiveHome.hasPrefix("/") else { return nil }
        return CodexWriterLockInspector().inspect(sessionID: sessionID, codexHome: effectiveHome)
    }
}
