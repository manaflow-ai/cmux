import Foundation

struct SubrouterProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Thin process adapter over the bundled, battle-tested Subrouter account manager.
actor SubrouterAccountService: SubrouterAccountServicing {
    typealias Runner = @Sendable (URL, [String]) async throws -> SubrouterProcessResult

    private let executableURL: URL?
    private let runner: Runner

    init(
        executableURL: URL? = SubrouterExecutable.resolve(),
        runner: Runner? = nil
    ) {
        self.executableURL = executableURL
        self.runner = runner ?? { executableURL, arguments in
            try await SubrouterAccountService.runProcess(executableURL, arguments)
        }
    }

    func listAccounts() async throws -> [SubrouterAccount] {
        try await accounts(arguments: ["accounts"])
    }

    func addLocalCodexAccount() async throws -> [SubrouterAccount] {
        _ = try await invoke(["import"])
        return try await accounts(arguments: ["accounts"])
    }

    static func parseAccounts(_ output: String) throws -> [SubrouterAccount] {
        try output.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  !line.hasPrefix("No Codex accounts found.") else {
                return nil
            }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count == 3,
                  columns.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw SubrouterAccountServiceError.malformedAccount(line)
            }
            return SubrouterAccount(id: columns[0], provider: columns[1], authMode: columns[2])
        }
    }

    private func accounts(arguments: [String]) async throws -> [SubrouterAccount] {
        let result = try await invoke(arguments)
        return try Self.parseAccounts(result.stdout)
    }

    @discardableResult
    private func invoke(_ arguments: [String]) async throws -> SubrouterProcessResult {
        guard let executableURL else {
            throw SubrouterAccountServiceError.executableUnavailable
        }
        let result: SubrouterProcessResult
        do {
            result = try await runner(executableURL, arguments)
        } catch {
            throw SubrouterAccountServiceError.launchFailed(String(describing: error))
        }
        guard result.status == 0 else {
            let message = [result.stderr, result.stdout]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SubrouterAccountServiceError.commandFailed(
                arguments: arguments,
                status: result.status,
                message: message
            )
        }
        return result
    }

    private static func runProcess(_ executableURL: URL, _ arguments: [String]) async throws -> SubrouterProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { process in
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: SubrouterProcessResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self)
                ))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
