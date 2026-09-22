import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    struct CodexTeamsAppServerRequestError: Error, CustomStringConvertible {
        let code: Int?
        let message: String
        let data: Any?

        var description: String { message }
    }

    static func reportCodexWriterConflicts(_ failures: [(String, Error)], codexHome: String) {
        let conflicts = failures.compactMap { identifier, error -> String? in
            guard let request = error as? CodexTeamsAppServerRequestError,
                  CodexWriterRecovery.isWriterConflict(code: request.code, message: request.message) else { return nil }
            return identifier
        }
        let reports = CodexWriterRecovery(temporaryDirectory: FileManager.default.temporaryDirectory)
            .inspect(sessionIDs: conflicts, codexHome: codexHome)
        for (identifier, _) in failures {
            if let report = reports[identifier] {
                let message = report.lock.state == .active
                    ? codexWriterReportMessage(report: report)
                    : codexWriterUnavailableMessage()
                cliWriteStderr(message + "\n")
            } else {
                cliWriteStderr(String(localized: "cli.codex.writer.recovery.watcherSkipped", defaultValue: "cmux could not check one watched session. Try resuming it again.") + "\n")
            }
        }
    }

    func runCodexWriterRecovery(commandArgs: [String]) throws {
        guard let request = CodexWriterRecoveryRequest(arguments: commandArgs) else {
            throw CLIError(message: String(localized: "cli.codex.writer.recovery.invalidCommand", defaultValue: "Invalid recovery command. Run `cmux codex-teams recover --help` for usage."))
        }
        let sessionID = request.sessionID
        let confirms = request.confirmsTermination
        let environment = ProcessInfo.processInfo.environment
        let codexHome = request.codexHome
            ?? CodexHomeResolver().resolve(
                ambientEnvironment: environment,
                fallbackHomeDirectory: NSHomeDirectory()
            )
        let recovery = CodexWriterRecovery(temporaryDirectory: FileManager.default.temporaryDirectory)
        let report = recovery.inspect(sessionID: sessionID, codexHome: codexHome)
        guard report.lock.state != .unavailable else {
            throw CLIError(message: Self.codexWriterUnavailableMessage())
        }
        guard report.lock.state == .active else {
            throw CLIError(message: String(localized: "cli.codex.writer.recovery.notBlocked", defaultValue: "This session is not blocked by another local session. Try resuming again."))
        }
        guard let orphan = report.orphanedHolder else {
            throw CLIError(message: Self.codexWriterReportMessage(report: report))
        }
        guard confirms else {
            throw CLIError(message: String(localized: "cli.codex.writer.recovery.confirm", defaultValue: "This will stop the abandoned background process blocking this session. Re-run with --yes to continue."))
        }
        guard recovery.terminateOrphanedHolder(
            sessionID: sessionID,
            codexHome: codexHome,
            pid: orphan.pid
        ) else {
            let refreshedReport = recovery.inspect(sessionID: sessionID, codexHome: codexHome)
            switch refreshedReport.lock.state {
            case .unavailable:
                throw CLIError(message: Self.codexWriterUnavailableMessage())
            case .available:
                throw CLIError(message: String(localized: "cli.codex.writer.recovery.notBlocked", defaultValue: "This session is not blocked by another local session. Try resuming again."))
            case .active:
                throw CLIError(message: Self.codexWriterReportMessage(report: refreshedReport))
            }
        }
        print(String(localized: "cli.codex.writer.recovery.signalled", defaultValue: "cmux asked the abandoned background process to stop. Wait for it to exit, then try resuming again."))
    }

    func guardCodexWriterBeforeResume(
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) throws {
        guard !CodexWriterRecovery.usesRemoteProvider(arguments: arguments),
              let sessionID = CodexWriterRecovery.codexResumeSessionID(arguments: arguments) else {
            return
        }
        let codexHome = CodexHomeResolver().resolve(
            launchEnvironment: environment,
            launchWorkingDirectory: workingDirectory,
            ambientEnvironment: environment,
            fallbackHomeDirectory: NSHomeDirectory()
        )
        let report = CodexWriterRecovery(temporaryDirectory: FileManager.default.temporaryDirectory)
            .inspect(sessionID: sessionID, codexHome: codexHome)
        guard report.lock.state == CodexWriterLockInspection.State.active else { return }
        cliWriteStderr(Self.codexWriterReportMessage(report: report) + "\n")
    }

    static func codexWriterRecoveryUsage() -> String {
        String(localized: "cli.codex.writer.recovery.usageWithHome", defaultValue: "Usage: cmux codex-teams recover <thread-id> [--codex-home <path>] [--yes]\n\nCheck whether a local session can be recovered. Use the thread ID of the session you want to resume. If it uses a custom storage location, pass that same absolute path with --codex-home. With --yes, stop a blocking background process only after confirming it has no active session or connected clients.")
    }

    static func codexWriterUnavailableMessage() -> String {
        String(localized: "cli.codex.writer.recovery.unavailable", defaultValue: "cmux could not safely check this session. Nothing was changed. Try again.")
    }

    static func codexWriterReportMessage(report: CodexWriterRecoveryReport) -> String {
        if let holder = report.orphanedHolder,
           let assessment = report.assessments.first(where: { $0.holder.pid == holder.pid }),
           assessment.classification == .orphanedAppServer {
            return String(localized: "cli.codex.writer.recovery.orphanedWithHome", defaultValue: "An abandoned background process is blocking this session. Run `cmux codex-teams recover --help` for recovery instructions, then try resuming again.")
        }
        return String(localized: "cli.codex.writer.recovery.active", defaultValue: "This session is already in use. Continue in its current terminal, or close it there and try resuming again. cmux will not stop it.")
    }

    static func codexWriterReportMessage(
        sessionID: String,
        codexHome: String
    ) -> String? {
        let report = CodexWriterRecovery(temporaryDirectory: FileManager.default.temporaryDirectory)
            .inspect(sessionID: sessionID, codexHome: codexHome)
        guard report.lock.state == CodexWriterLockInspection.State.active else { return nil }
        return Self.codexWriterReportMessage(report: report)
    }
}
