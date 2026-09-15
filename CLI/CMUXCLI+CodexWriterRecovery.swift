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
        for (identifier, error) in failures {
            if let report = reports[identifier], report.lock.state == .active {
                cliWriteStderr(codexWriterReportMessage(sessionID: identifier, report: report) + "\n")
            } else {
                cliWriteStderr("cmux codex-teams watcher skipped thread \(identifier): \(error)\n")
            }
        }
    }

    func runCodexWriterRecovery(commandArgs: [String]) throws {
        guard let request = CodexWriterRecoveryRequest(arguments: commandArgs) else {
            throw CLIError(message: Self.codexWriterRecoveryUsage())
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
            throw CLIError(message: Self.codexWriterUnavailableMessage(sessionID: sessionID, lockPath: report.lock.lockPath))
        }
        guard report.lock.state == .active else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.codex.writer.recovery.notBlocked", defaultValue: "Codex thread %@ is not currently blocked by an active local writer lock."),
                sessionID
            ))
        }
        guard let orphan = report.orphanedHolder else {
            throw CLIError(message: Self.codexWriterReportMessage(sessionID: sessionID, report: report))
        }
        guard confirms else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.codex.writer.recovery.confirm", defaultValue: "This will terminate orphaned Codex app-server PID %d. Re-run with --yes to continue."),
                orphan.pid
            ))
        }
        guard recovery.terminateOrphanedHolder(
            sessionID: sessionID,
            codexHome: codexHome,
            pid: orphan.pid
        ) else {
            let refreshedReport = recovery.inspect(sessionID: sessionID, codexHome: codexHome)
            switch refreshedReport.lock.state {
            case .unavailable:
                throw CLIError(message: Self.codexWriterUnavailableMessage(
                    sessionID: sessionID,
                    lockPath: refreshedReport.lock.lockPath
                ))
            case .available:
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.codex.writer.recovery.notBlocked", defaultValue: "Codex thread %@ is not currently blocked by an active local writer lock."),
                    sessionID
                ))
            case .active:
                throw CLIError(message: Self.codexWriterReportMessage(
                    sessionID: sessionID,
                    report: refreshedReport
                ))
            }
        }
        print(String.localizedStringWithFormat(
            String(localized: "cli.codex.writer.recovery.signalled", defaultValue: "Sent SIGTERM to orphaned Codex app-server PID %d for thread %@. Retry resume after it exits."),
            orphan.pid,
            sessionID
        ))
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
        cliWriteStderr(Self.codexWriterReportMessage(sessionID: sessionID, report: report) + "\n")
    }

    static func codexWriterRecoveryUsage() -> String {
        String(localized: "cli.codex.writer.recovery.usageWithHome", defaultValue: "Usage: cmux codex-teams recover <thread-id> [--codex-home <path>] [--yes]\n\nInspect the local Codex writer lock and, with --yes, terminate only a holder proven to be an orphaned app-server.")
    }

    static func codexWriterUnavailableMessage(sessionID: String, lockPath: String) -> String {
        String.localizedStringWithFormat(
            String(localized: "cli.codex.writer.recovery.unavailable", defaultValue: "cmux could not safely inspect the Codex writer lock for thread %@. No process was started or terminated. Lock: %@"),
            sessionID,
            lockPath
        )
    }

    static func codexWriterReportMessage(sessionID: String, report: CodexWriterRecoveryReport) -> String {
        let lock = report.lock.lockPath
        if let holder = report.orphanedHolder,
           let assessment = report.assessments.first(where: { $0.holder.pid == holder.pid }),
           assessment.classification == .orphanedAppServer {
            return String.localizedStringWithFormat(
                String(localized: "cli.codex.writer.recovery.orphanedWithHome", defaultValue: "Codex thread %@ is blocked by an orphaned app-server (PID %d, parent PID %d, executable %@). Run `cmux codex-teams recover %@ --codex-home %@ --yes`, then retry resume. Lock: %@"),
                sessionID,
                holder.pid,
                holder.parentPID,
                holder.validatedExecutableName
                    ?? String(localized: "cli.codex.writer.recovery.unknownExecutable", defaultValue: "unidentified process"),
                sessionID,
                "'" + report.lock.codexHome.replacingOccurrences(of: "'", with: "'\\''") + "'",
                lock
            )
        }
        let ownerText = report.holders.map {
            String.localizedStringWithFormat(
                String(localized: "cli.codex.writer.recovery.owner", defaultValue: "PID %d, parent PID %d, executable %@"),
                $0.pid,
                $0.parentPID,
                $0.validatedExecutableName
                    ?? String(localized: "cli.codex.writer.recovery.unknownExecutable", defaultValue: "unidentified process")
            )
        }.joined(separator: String(localized: "cli.codex.writer.recovery.ownerSeparator", defaultValue: "; "))
        return String.localizedStringWithFormat(
            String(localized: "cli.codex.writer.recovery.active", defaultValue: "Codex thread %@ already has an active writer (%@). Continue in the owning Codex session, then retry. cmux will not terminate it. Lock: %@"),
            sessionID,
            ownerText.isEmpty
                ? String(localized: "cli.codex.writer.recovery.unknownHolder", defaultValue: "unknown holder")
                : ownerText,
            lock
        )
    }

    static func codexWriterReportMessage(
        sessionID: String,
        codexHome: String
    ) -> String? {
        let report = CodexWriterRecovery(temporaryDirectory: FileManager.default.temporaryDirectory)
            .inspect(sessionID: sessionID, codexHome: codexHome)
        guard report.lock.state == CodexWriterLockInspection.State.active else { return nil }
        return Self.codexWriterReportMessage(sessionID: sessionID, report: report)
    }
}
