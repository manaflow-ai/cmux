import Darwin
import Foundation

/// Shared ownership inspection and explicit orphan termination policy.
public struct CodexWriterRecovery: Sendable {
    private let lockInspector: CodexWriterLockInspector
    private let processes: any CodexWriterProcessInspecting

    public init(temporaryDirectory: URL) {
        lockInspector = CodexWriterLockInspector()
        processes = CodexWriterSystemProcesses(temporaryDirectory: temporaryDirectory)
    }

    init(processes: any CodexWriterProcessInspecting) {
        lockInspector = CodexWriterLockInspector()
        self.processes = processes
    }

    public func inspect(sessionID: String, codexHome: String) -> CodexWriterRecoveryReport {
        let lock = lockInspector.inspect(sessionID: sessionID, codexHome: codexHome)
        guard lock.state == .active else {
            return CodexWriterRecoveryReport(
                lock: lock,
                holders: [],
                assessments: [],
                processScanIsComplete: true
            )
        }
        return report(lock: lock, snapshot: processes.snapshot(locks: [lock]))
    }

    /// Inspects a diagnostic batch using one short-lived kernel process snapshot.
    public func inspect(sessionIDs: [String], codexHome: String) -> [String: CodexWriterRecoveryReport] {
        let locks = Dictionary(uniqueKeysWithValues: Set(sessionIDs).map {
            ($0, lockInspector.inspect(sessionID: $0, codexHome: codexHome))
        })
        let snapshot = processes.snapshot(locks: locks.values.filter { $0.state == .active })
        return locks.mapValues { report(lock: $0, snapshot: snapshot) }
    }

    private func report(lock: CodexWriterLockInspection, snapshot: CodexWriterProcessSnapshot) -> CodexWriterRecoveryReport {
        let holders = CodexWriterFileIdentity(lock: lock).flatMap { snapshot.holders[$0] } ?? []
        return CodexWriterRecoveryReport(
            lock: lock, holders: holders,
            assessments: holders.map { CodexWriterRecoveryAssessment(holder: $0, watchedAppServerPorts: snapshot.watchedPorts) },
            processScanIsComplete: snapshot.isComplete
        )
    }

    public func terminateOrphanedHolder(
        sessionID: String,
        codexHome: String,
        pid: Int32
    ) -> Bool {
        let initial = inspect(sessionID: sessionID, codexHome: codexHome)
        guard initial.lock.state == .active,
              initial.processScanIsComplete,
              initial.orphanedHolder?.pid == pid,
              let initialAssessment = initial.assessments.first(where: { $0.holder.pid == pid }) else {
            return false
        }
        let current = inspect(sessionID: sessionID, codexHome: codexHome)
        guard current.lock == initial.lock,
              current.processScanIsComplete,
              current.orphanedHolder?.pid == pid,
              let currentAssessment = current.assessments.first(where: { $0.holder.pid == pid }),
              currentAssessment.holder == initialAssessment.holder,
              lockInspector.inspect(sessionID: sessionID, codexHome: codexHome) == current.lock else {
            return false
        }
        return processes.terminate(currentAssessment.holder)
    }

    public static func resumeSessionID(arguments: [String]) -> String? {
        guard let commandIndex = arguments.firstIndex(where: {
            let value = $0.lowercased()
            return value == "resume" || value == "recover"
        }) else {
            return nil
        }
        return arguments.dropFirst(commandIndex + 1).compactMap { argument in
            UUID(uuidString: argument)?.uuidString.lowercased()
        }.first
    }

    public static func codexHomeOverride(arguments: [String]) -> String? {
        guard arguments.first?.lowercased() == "recover",
              let index = arguments.firstIndex(of: "--codex-home"),
              index + 1 < arguments.count else {
            return nil
        }
        let path = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    public static func usesRemoteProvider(arguments: [String]) -> Bool {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return false }
            if argument == "--remote" || argument.hasPrefix("--remote=") { return true }
            index += 1
        }
        return false
    }

    public static func isWriterConflict(code: Int?, message: String?) -> Bool {
        guard code == -32600, let message else { return false }
        let normalized = message
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.contains("already has an active writer")
    }

    public static func codexResumeSessionID(arguments: [String]) -> String? {
        guard let executable = arguments.first,
              URL(fileURLWithPath: executable).lastPathComponent.lowercased() == "codex",
              arguments.dropFirst().first?.lowercased() == "resume" else {
            return nil
        }
        return arguments.dropFirst(2).compactMap { argument in
            UUID(uuidString: argument)?.uuidString.lowercased()
        }.first
    }

}
