import Darwin
import Foundation
import OSLog

/// Reads the same CodeRouter Cloud account view shown by `cmux cr accounts`.
/// CodeRouter's organization catalog is keyed by the Stack team UUID. Newer
/// CLI versions accept that ID on the account read, so a sidebar refresh does
/// not need to mutate the user's active organization.
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
        knownOrganizationID: String? = nil,
        run: Run = runCLI
    ) async throws -> Snapshot {
        try Task.checkCancellation()
        guard let teamID = cmuxTeamID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !teamID.isEmpty,
              var organizationID = try await resolvedOrganizationID(
                  for: teamID,
                  name: cmuxTeamName,
                  knownOrganizationID: knownOrganizationID,
                  run: run
              ) else {
            logger.error("No CodeRouter organization matched cmux team ID \(cmuxTeamID ?? "<nil>", privacy: .public), name \(String(describing: cmuxTeamName), privacy: .public)")
            throw accountError("The selected cmux team is not mapped to a coderouter organization.")
        }

        // Prefer the team-scoped read. It sends the selected organization in the
        // request and leaves the terminal's shared active organization untouched.
        try Task.checkCancellation()
        let payload: (organizationID: String?, accounts: [CloudTreeNode.CoderouterAccount])
        do {
            payload = try await readAccounts(for: organizationID, run: run)
        } catch {
            // Bundled CodeRouter 0.3.15 predates `accounts --team`. Keep the
            // old path as a compatibility fallback until that binary is
            // released and included in cmux.
            guard isUnsupportedTeamOption(error) else { throw error }
            let legacyOrganizationID: String
            if UUID(uuidString: teamID) != nil {
                // The organization catalog uses Stack team UUIDs as its IDs.
                // Do not pay for an `org list` just to rediscover this value.
                legacyOrganizationID = teamID
            } else {
                guard let name = cmuxTeamName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty,
                      let matched = try await matchingOrganizationID(for: teamID, name: name, run: run) else {
                    throw error
                }
                legacyOrganizationID = matched
            }
            organizationID = legacyOrganizationID
            logger.info("Falling back to active CodeRouter organization selection for legacy CLI")
            var legacyPayload = try await readAccounts(run: run)
            if legacyPayload.organizationID != legacyOrganizationID {
                try Task.checkCancellation()
                _ = try await run(["org", "switch", legacyOrganizationID])
                try Task.checkCancellation()
                legacyPayload = try await readAccounts(run: run)
            }
            payload = legacyPayload
        }
        guard payload.organizationID == organizationID else {
            logger.error("CodeRouter accounts were for org ID \(payload.organizationID ?? "<nil>", privacy: .public), expected \(organizationID, privacy: .public)")
            throw accountError("coderouter returned accounts for a different team.")
        }
        logger.info("Loaded \(payload.accounts.count, privacy: .public) CodeRouter accounts for org ID \(organizationID, privacy: .public)")
        return Snapshot(organizationID: organizationID, accounts: payload.accounts)
    }

    private static func resolvedOrganizationID(
        for cmuxTeamID: String?,
        name cmuxTeamName: String?,
        knownOrganizationID: String?,
        run: Run
    ) async throws -> String? {
        if let cmuxTeamID = cmuxTeamID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cmuxTeamID.isEmpty,
           UUID(uuidString: cmuxTeamID) != nil {
            return cmuxTeamID
        }
        if let knownOrganizationID = knownOrganizationID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !knownOrganizationID.isEmpty,
           UUID(uuidString: knownOrganizationID) != nil {
            return knownOrganizationID
        }
        guard let cmuxTeamName = cmuxTeamName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cmuxTeamName.isEmpty else { return nil }
        return try await matchingOrganizationID(for: cmuxTeamID, name: cmuxTeamName, run: run)
    }

    /// Removes one account from the CodeRouter organization of the selected cmux
    /// team, selecting that organization first exactly as `accounts` reads it.
    static func remove(
        accountID: String,
        for cmuxTeamID: String?,
        name cmuxTeamName: String?,
        knownOrganizationID: String? = nil,
        run: Run = runCLI
    ) async throws {
        guard UUID(uuidString: accountID) != nil else {
            throw accountError("That coderouter account ID is not valid.")
        }
        let snapshot = try await snapshot(
            for: cmuxTeamID,
            name: cmuxTeamName,
            knownOrganizationID: knownOrganizationID,
            run: run
        )
        do {
            _ = try await run(["remove", accountID, "--yes", "--team", snapshot.organizationID])
        } catch {
            // Compatibility with the pre-team-scoped CLI. This legacy path is
            // only used when the direct command is not understood.
            guard isUnsupportedTeamOption(error) else { throw error }
            _ = try await run(["org", "switch", snapshot.organizationID])
            _ = try await run(["remove", accountID, "--yes"])
        }
        logger.info("Removed CodeRouter account \(accountID, privacy: .public)")
    }

    private static func readAccounts(
        for organizationID: String,
        run: Run
    ) async throws -> (organizationID: String?, accounts: [CloudTreeNode.CoderouterAccount]) {
        try await readAccounts(
            arguments: ["accounts", "--json", "--team", organizationID],
            run: run
        )
    }

    private static func readAccounts(run: Run) async throws -> (organizationID: String?, accounts: [CloudTreeNode.CoderouterAccount]) {
        try await readAccounts(arguments: ["accounts", "--json"], run: run)
    }

    private static func readAccounts(
        arguments: [String],
        run: Run
    ) async throws -> (organizationID: String?, accounts: [CloudTreeNode.CoderouterAccount]) {
        let output = try await run(arguments)
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

    /// The bundled pre-team-scoped CLI reports a command usage string that
    /// does not mention `--team`. A newer CLI can fail for auth, network, or
    /// membership reasons; those failures must be returned to the sidebar and
    /// must never mutate the user's shared active organization.
    private static func isUnsupportedTeamOption(_ error: Error) -> Bool {
        let message = (error as NSError).localizedDescription.lowercased()
        if message.contains("unexpected argument") ||
            message.contains("unknown option") ||
            message.contains("unrecognized option") ||
            message.contains("wasn't expected") {
            return message.contains("--team")
        }
        if message.contains("usage: coderouter accounts") ||
            message.contains("usage: coderouter remove") {
            return !message.contains("--team")
        }
        return false
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
            if process.isRunning {
                _ = Darwin.kill(identifier, SIGKILL)
            }
        }
        try? stdout.close()
        try? stderr.close()
    }
}
