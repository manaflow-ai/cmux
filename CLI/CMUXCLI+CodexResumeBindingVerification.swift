import Foundation
import CMUXAgentLaunch
import OSLog

nonisolated private let codexResumeBindingLogger = Logger(
    subsystem: "com.cmuxterm.cli",
    category: "CodexResumeBinding"
)

extension CMUXCLI {
    enum CodexResumeBindingCurrentLookup {
        case binding([String: Any]?)
        case unsupported
        case unavailable
    }

    func codexResumeBindingVerification(
        sessionId: String,
        transcriptPath: String?,
        launchCommand: AgentHookLaunchCommandRecord?
    ) -> CodexSessionResumeVerification {
        let environment = ProcessInfo.processInfo.environment
        let codexHome = codexResumeBindingEffectiveHome(
            launchEnvironment: launchCommand?.environment,
            ambientEnvironment: environment
        )
        return CodexSessionResumeVerifier().verify(
            sessionId: sessionId,
            transcriptPath: transcriptPath,
            codexHome: codexHome
        )
    }

    func codexResumeBindingEffectiveHome(
        launchEnvironment: [String: String]?,
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let launchHome = normalizedHookValue(launchEnvironment?["CODEX_HOME"]) {
            return (launchHome as NSString).expandingTildeInPath
        }
        if let ambientHome = normalizedHookValue(ambientEnvironment["CODEX_HOME"]) {
            return (ambientHome as NSString).expandingTildeInPath
        }
        let home = normalizedHookValue(ambientEnvironment["HOME"]) ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .path
    }

    func codexResumeBindingCurrentLookup(
        client: SocketClient,
        workspaceId: String,
        surfaceId: String
    ) -> CodexResumeBindingCurrentLookup {
        do {
            let payload = try client.sendV2(
                method: "surface.resume.get",
                params: ["workspace_id": workspaceId, "surface_id": surfaceId],
                responseTimeout: 2
            )
            return .binding(payload["resume_binding"] as? [String: Any])
        } catch let error as CLIError where error.v2Code == "method_not_found"
                || error.v2Code == "unrecognized_method" {
            return .unsupported
        } catch {
            return .unavailable
        }
    }

    func codexResumeBindingProvenance(
        binding: [String: Any],
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AgentResumeEvidenceProvenance? {
        guard let checkpointID = normalizedHookValue(
            (binding["checkpoint_id"] as? String) ?? (binding["checkpointId"] as? String)
        ) else {
            return nil
        }
        let launchCommand = binding["launch_command"] as? [String: Any]
        let launchEnvironment = (launchCommand?["environment"] as? [String: String])
            ?? (binding["environment"] as? [String: String])
        let codexHome = codexResumeBindingEffectiveHome(
            launchEnvironment: launchEnvironment,
            ambientEnvironment: ambientEnvironment
        )
        switch CodexSessionResumeVerifier().verify(
            sessionId: checkpointID,
            transcriptPath: nil,
            codexHome: codexHome
        ) {
        case .exists(let evidence):
            return evidence.provenance
        case .missing, .unavailable:
            return nil
        }
    }

    func codexResumeBindingShouldPublish(
        client: SocketClient,
        workspaceId: String,
        surfaceId: String,
        incoming: CodexSessionResumeEvidence,
        telemetry: CLISocketSentryTelemetry? = nil
    ) -> Bool {
        guard incoming.provenance.mayOwnBinding else {
            logCodexResumeBindingRejection(
                reason: "incoming-lower-provenance",
                sessionId: incoming.sessionId,
                incoming: incoming.provenance,
                existing: nil,
                telemetry: telemetry
            )
            return false
        }
        // A verified TUI checkpoint is the strongest supported evidence and may
        // legitimately rebind after /new or a fresh TUI launch. Querying the
        // current binding is only needed for legacy/unclassified evidence, where
        // the no-downgrade rule has something to protect.
        guard incoming.provenance != .tui else { return true }

        switch codexResumeBindingCurrentLookup(
            client: client,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        ) {
        case .binding(let binding):
            guard let binding else { return true }
            guard let existingProvenance = codexResumeBindingProvenance(binding: binding) else {
                logCodexResumeBindingRejection(
                    reason: "existing-binding-unverified",
                    sessionId: incoming.sessionId,
                    incoming: incoming.provenance,
                    existing: nil,
                    telemetry: telemetry
                )
                return false
            }
            guard incoming.provenance.canReplace(existingProvenance) else {
                logCodexResumeBindingRejection(
                    reason: "incoming-lower-than-existing",
                    sessionId: incoming.sessionId,
                    incoming: incoming.provenance,
                    existing: existingProvenance,
                    telemetry: telemetry
                )
                return false
            }
            return true
        case .unsupported:
            // Older tagged CLIs may be talking to an app predating
            // surface.resume.get.  Preserve legacy transcript-backed behavior;
            // explicit exec/review evidence was already rejected above.
            return true
        case .unavailable:
            logCodexResumeBindingRejection(
                reason: "existing-binding-unavailable",
                sessionId: incoming.sessionId,
                incoming: incoming.provenance,
                existing: nil,
                telemetry: telemetry
            )
            return false
        }
    }

    func logCodexResumeBindingRejection(
        reason: String,
        sessionId: String,
        incoming: AgentResumeEvidenceProvenance?,
        existing: AgentResumeEvidenceProvenance?,
        telemetry: CLISocketSentryTelemetry?
    ) {
        let shortSessionID = String(sessionId.prefix(12))
        let incomingValue = incoming?.logValue ?? "none"
        let existingValue = existing?.logValue ?? "none"
        codexResumeBindingLogger.notice(
            "Codex resume binding publish rejected reason=\(reason, privacy: .public) session=\(shortSessionID, privacy: .private(mask: .hash)) incoming=\(incomingValue, privacy: .public) existing=\(existingValue, privacy: .public)"
        )
        telemetry?.breadcrumb(
            "codex-resume-binding.publish-rejected",
            data: [
                "reason": reason,
                "incoming_provenance": incomingValue,
                "existing_provenance": existingValue,
                "has_session_id": !sessionId.isEmpty,
            ]
        )
    }
}
