import Foundation
import CMUXAgentLaunch

extension CMUXCLI {
    /// Converts Prime's durable session file into the managed resume command
    /// used by both surface restore and Agent Hibernation.
    func preferredPrimeAgentResumeLaunchCommand(
        current: AgentHookLaunchCommandRecord?,
        mapped: ClaudeHookSessionRecord?,
        transcriptPath: String?
    ) -> AgentHookLaunchCommandRecord? {
        guard let rawPath = normalizedHookValue(transcriptPath) else {
            return current ?? mapped?.launchCommand
        }
        let sessionFile = NSString(string: rawPath).expandingTildeInPath
        guard sessionFile.hasPrefix("/"), !sessionFile.hasSuffix("/") else {
            return current ?? mapped?.launchCommand
        }
        let trustedCandidate = [current, mapped?.launchCommand]
            .compactMap { $0 }
            .first { AgentLaunchCaptureTrust.launcherDescribesKind($0.launcher, kind: "prime-agent") }
        let candidateArguments = trustedCandidate?.arguments ?? []
        let executable = PrimeAgentResumeArgv.resumeExecutable(
            executablePath: trustedCandidate?.executablePath,
            arguments: candidateArguments
        )
        let preservedArguments: [String]
        if trustedCandidate != nil, !candidateArguments.isEmpty {
            guard let preserved = PrimeAgentResumeArgv.preservedArguments(
                executablePath: trustedCandidate?.executablePath,
                arguments: candidateArguments
            ) else {
                return current ?? mapped?.launchCommand
            }
            preservedArguments = preserved
        } else {
            preservedArguments = []
        }
        return AgentHookLaunchCommandRecord(
            launcher: "prime-agent",
            executablePath: executable,
            arguments: [executable, "--resume", sessionFile] + preservedArguments,
            workingDirectory: trustedCandidate?.workingDirectory,
            environment: trustedCandidate?.environment,
            verificationHome: trustedCandidate?.verificationHome,
            capturedAt: trustedCandidate?.capturedAt ?? Date().timeIntervalSince1970,
            source: "agent-hook"
        )
    }
}
