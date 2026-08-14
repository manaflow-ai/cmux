import Foundation
import CMUXAgentLaunch
import OSLog

nonisolated private let codexResumeBindingLogger = Logger(
    subsystem: "com.cmuxterm.cli",
    category: "CodexResumeBinding"
)

extension CMUXCLI {
    /// Verifies a hook checkpoint before the standalone CLI publishes it.
    ///
    /// Hook publication is intentionally decided in this short-lived CLI
    /// process, not on cmux's MainActor or socket worker. The verifier starts
    /// with one indexed SQLite lookup and applies hard byte, line, and fallback
    /// candidate limits to the legacy rollout path, so the bounded inspection
    /// cannot turn an app UI/socket lane into a history loader.
    func codexResumeBindingVerification(
        sessionId: String,
        transcriptPath: String?,
        launchCommand: AgentHookLaunchCommandRecord?
    ) -> CodexSessionResumeVerification {
        let environment = ProcessInfo.processInfo.environment
        let codexHome = codexResumeBindingEffectiveHome(
            launchEnvironment: launchCommand?.environment,
            launchVerificationHome: launchCommand?.verificationHome,
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
        launchVerificationHome: String? = nil,
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let launchHome = normalizedHookValue(launchEnvironment?["CODEX_HOME"]) {
            return (launchHome as NSString).expandingTildeInPath
        }
        if let launchHome = normalizedHookValue(launchVerificationHome)
            ?? normalizedHookValue(launchEnvironment?["HOME"]) {
            return URL(fileURLWithPath: (launchHome as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
                .path
        }
        if let ambientHome = normalizedHookValue(ambientEnvironment["CODEX_HOME"]) {
            return (ambientHome as NSString).expandingTildeInPath
        }
        let home = normalizedHookValue(ambientEnvironment["HOME"]) ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .path
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
