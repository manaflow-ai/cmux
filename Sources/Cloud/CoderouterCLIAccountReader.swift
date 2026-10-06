import Darwin
import Foundation
import OSLog

/// Reads the same CodeRouter Cloud account view shown by `cmux cr accounts`.
/// CodeRouter organizations have their own IDs, so the cmux team UUID is never
/// passed to CodeRouter directly.
enum CoderouterCLIAccountReader {
    typealias Run = @Sendable (_ arguments: [String]) async throws -> Data

    struct Snapshot {
        let organizationID: String
        let accounts: [CloudTreeNode.CoderouterAccount]
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "coderouter-accounts")

    static func accounts(
        for cmuxTeamID: String?,
        name cmuxTeamName: String?,
        run: Run = runCLI
    ) async throws -> [CloudTreeNode.CoderouterAccount] {
        let snapshot = try await snapshot(for: cmuxTeamID, name: cmuxTeamName, run: run)
        return snapshot.accounts
    }

    /// Reads the selected team's CodeRouter organization and account rows in
    /// one operation. The organization ID is retained by the sidebar so an
    /// account created from a team row can carry an explicit destination.
    static func snapshot(
        for cmuxTeamID: String?,
        name cmuxTeamName: String?,
        run: Run = runCLI
    ) async throws -> Snapshot {
        try Task.checkCancellation()
        guard let cmuxTeamName = cmuxTeamName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cmuxTeamName.isEmpty,
              let organizationID = try await matchingOrganizationID(for: cmuxTeamID, name: cmuxTeamName, run: run) else {
            logger.error("No CodeRouter organization matched cmux team ID \(cmuxTeamID ?? "<nil>", privacy: .public), name \(String(describing: cmuxTeamName), privacy: .public)")
            throw accountError("The selected cmux team is not mapped to a coderouter organization.")
        }

        // `accounts` reads the CLI's active organization, which the user's terminal
        // shares. Its payload names that organization as `teamId`, so trust only the
        // payload and switch only when the selected team's organization is not active.
        var payload = try await readAccounts(run: run)
        if payload.organizationID != organizationID {
            try Task.checkCancellation()
            _ = try await run(["org", "switch", organizationID])
            try Task.checkCancellation()
            payload = try await readAccounts(run: run)
        }
        guard payload.organizationID == organizationID else {
            logger.error("CodeRouter accounts were for org ID \(payload.organizationID ?? "<nil>", privacy: .public), expected \(organizationID, privacy: .public)")
            throw accountError("coderouter organization did not switch to the selected team.")
        }
        logger.info("Loaded \(payload.accounts.count, privacy: .public) CodeRouter accounts for org ID \(organizationID, privacy: .public)")
        return Snapshot(organizationID: organizationID, accounts: payload.accounts)
    }

    /// Removes one account from the CodeRouter organization of the selected cmux
    /// team, selecting that organization first exactly as `accounts` reads it.
    static func remove(
        accountID: String,
        for cmuxTeamID: String?,
        name cmuxTeamName: String?,
        run: Run = runCLI
    ) async throws {
        guard UUID(uuidString: accountID) != nil else {
            throw accountError("That coderouter account ID is not valid.")
        }
        _ = try await accounts(for: cmuxTeamID, name: cmuxTeamName, run: run)
        _ = try await run(["remove", accountID, "--yes"])
        logger.info("Removed CodeRouter account \(accountID, privacy: .public)")
    }

    private static func readAccounts(run: Run) async throws -> (organizationID: String?, accounts: [CloudTreeNode.CoderouterAccount]) {
        let output = try await run(["accounts", "--json"])
        let object = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        let accounts = object?["accounts"] as? [[String: Any]] ?? []
        let result: [CloudTreeNode.CoderouterAccount] = accounts.compactMap { account in
            guard let id = account["id"] as? String,
                  let provider = (account["provider"] as? String) ?? (account["kind"] as? String) else {
                return nil
            }
            return CloudTreeNode.CoderouterAccount(
                id: id,
                provider: CoderouterProvider(id: provider.lowercased()),
                label: account["label"] as? String,
                state: account["state"] as? String,
                remainingPercent: remainingPercent(usage: account["usage"]),
                identifier: account["identifier"] as? String
            )
        }
        return (object?["teamId"] as? String, result)
    }

    /// The share of the account's current rate-limit window still unused, the
    /// "93% left" `cr accounts` prints. Nil when the provider reports no window.
    private static func remainingPercent(usage: Any?) -> Int? {
        guard let usage = usage as? [String: Any],
              let rateLimit = usage["rate_limit"] as? [String: Any],
              let window = rateLimit["primary_window"] as? [String: Any],
              let used = (window["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        return min(100, max(0, Int((100 - used).rounded())))
    }

    private static func matchingOrganizationID(for cmuxTeamID: String?, name cmuxTeamName: String, run: Run) async throws -> String? {
        let output = try await run(["org", "list"])
        let wanted = normalized(cmuxTeamName)
        let organizations = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { rawLine -> (id: String, name: String)? in
            let tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let candidateID = tokens.last,
                  UUID(uuidString: String(candidateID)) != nil else { return nil }
            let candidateName = tokens.dropLast().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            return (String(candidateID), normalized(candidateName))
        }
        if let exact = organizations.first(where: { $0.id == cmuxTeamID }) { return exact.id }
        let matches = organizations.filter { $0.name == wanted }
        guard matches.count <= 1 else {
            throw accountError("More than one CodeRouter organization matches the selected team.")
        }
        return matches.first?.id
    }

    private static func normalized(_ value: String) -> String {
        var result = value.lowercased()
            .replacingOccurrences(of: "’s team", with: "")
            .replacingOccurrences(of: "'s team", with: "")
            .replacingOccurrences(of: " team", with: "")
        result = result.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }.reduce(into: "") { $0.append($1) }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func accountError(_ message: String) -> NSError {
        NSError(domain: "CoderouterCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// The CodeRouter CLI `cmux cr` runs, in its order (`resolveCoderouterExecutable`):
    /// the app-bundled core, then PATH (`coderouter`, then `cr`), then the
    /// installer's bin directory. Two versions sharing one config file can make
    /// it unreadable to each other, so the sidebar never runs a different one.
    static func resolvedExecutable(
        bundleURL: URL = Bundle.main.bundleURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let bundled = bundleURL.appendingPathComponent("Contents/Resources/bin/coderouter").path
        if isExecutable(bundled) { return bundled }
        let searchPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for name in ["coderouter", "cr"] {
            for directory in searchPath where !directory.isEmpty {
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
                if isExecutable(candidate) { return candidate }
            }
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let installRoot = environment["CODEROUTER_INSTALL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: home).appendingPathComponent(".coderouter").path
        let installed = URL(fileURLWithPath: installRoot).appendingPathComponent("bin/coderouter").path
        return isExecutable(installed) ? installed : nil
    }

    @Sendable private static func runCLI(_ arguments: [String]) async throws -> Data {
        guard let executable = resolvedExecutable() else {
            throw accountError("coderouter is not installed. Run cmux cr in a terminal to install it.")
        }
        // Same isolation as `cmux cr`: CodeRouter never sees cmux's CMUX_* context.
        let environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("CMUX_") && !key.hasPrefix("CMUXD_")
        }
        let result = try await runProcess(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        return result.stdout
    }

    /// Runs a CLI while draining stdout and stderr concurrently. Waiting for
    /// termination before reading either pipe deadlocks once a chatty command
    /// fills the kernel pipe buffer (the old sidebar reader did exactly that).
    /// This remains internal so the large-output behavior can be covered without
    /// depending on a real CodeRouter installation.
    static func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> (stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let stdoutFileDescriptor = output.fileHandleForReading.fileDescriptor
        let stderrFileDescriptor = error.fileHandleForReading.fileDescriptor

        let stdoutRead = Task.detached(priority: .utility) {
            Self.drain(fileDescriptor: stdoutFileDescriptor)
        }
        let stderrRead = Task.detached(priority: .utility) {
            Self.drain(fileDescriptor: stderrFileDescriptor)
        }
        let cancellation = CoderouterProcessCancellation(
            process: process,
            stdout: output.fileHandleForReading,
            stderr: error.fileHandleForReading
        )

        let status: Int32
        do {
            status = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { process in
                        continuation.resume(returning: process.terminationStatus)
                    }
                    do {
                        try process.run()
                        // Cancellation may arrive between the check above and
                        // Process.run(); do not leave that child behind.
                        if Task.isCancelled {
                            cancellation.cancel()
                        }
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            }, onCancel: {
                cancellation.cancel()
            })
            try Task.checkCancellation()
        } catch {
            cancellation.cancel()
            stdoutRead.cancel()
            stderrRead.cancel()
            _ = await stdoutRead.value
            _ = await stderrRead.value
            throw error
        }

        let stdout = await stdoutRead.value
        let stderr = await stderrRead.value
        guard status == 0 else {
            let message = String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            logger.error("coderouter \(arguments.joined(separator: " "), privacy: .public) failed: \(message, privacy: .public)")
            throw NSError(domain: "CoderouterCLI", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
        return (stdout, stderr)
    }

    /// Reads one pipe until EOF without blocking the task that waits for the
    /// child process. The descriptor is the only value crossing the detached
    /// task boundary, so Foundation pipe objects remain actor-local.
    private static func drain(fileDescriptor: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                return data
            } else if errno == EINTR {
                continue
            } else {
                return data
            }
        }
    }
}

/// Process and pipe handles captured by the cancellation handler. Closing the
/// readers wakes the drain tasks, while SIGKILL guarantees a child that ignores
/// SIGTERM cannot keep a team refresh alive after the user switches teams.
private final class CoderouterProcessCancellation: @unchecked Sendable {
    private let process: Process
    private let stdout: FileHandle
    private let stderr: FileHandle

    init(process: Process, stdout: FileHandle, stderr: FileHandle) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
    }

    func cancel() {
        let identifier = process.processIdentifier
        if process.isRunning, identifier > 1 {
            process.terminate()
            _ = Darwin.kill(identifier, SIGKILL)
        }
        try? stdout.close()
        try? stderr.close()
    }
}
