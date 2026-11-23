import Darwin
import Foundation
import OSLog

/// Why the sidebar could not read or change the team's CodeRouter accounts.
/// Each case maps to one actionable message; raw CLI output stays in the log.
enum CoderouterCLIFailure: Error, Equatable, Sendable, LocalizedError {
    /// No CodeRouter CLI is bundled or installed.
    case notInstalled
    /// The resolved CLI predates team-scoped commands (`--team`, 0.3.16).
    case outdated
    /// The app is signed out, or the CLI rejected the app session.
    case signInRequired
    /// The signed-in account is not a member of the selected team.
    case notMember
    /// The team's plan does not include CodeRouter.
    case planRequired
    /// The network or the control plane is down.
    case unreachable
    /// Anything else.
    case unavailable
    /// The app's session was being revalidated or replaced while it was
    /// captured. Transient: the next refresh retries, nothing is reported.
    case sessionChanging

    var message: String {
        switch self {
        case .notInstalled:
            return String(localized: "coderouter.failure.notInstalled", defaultValue: "Coderouter is missing from this cmux install. Update cmux, then retry.")
        case .outdated:
            return String(localized: "coderouter.failure.outdated", defaultValue: "This Coderouter version can't load team accounts. Update cmux, then retry.")
        case .signInRequired:
            return String(localized: "coderouter.failure.signIn", defaultValue: "Your cmux sign-in expired. Sign in again, then retry.")
        case .notMember:
            return String(localized: "coderouter.failure.notMember", defaultValue: "Your cmux account can't manage Coderouter for this team.")
        case .planRequired:
            return String(localized: "coderouter.failure.plan", defaultValue: "Coderouter needs a cmux Pro or Team plan.")
        case .unreachable:
            return String(localized: "coderouter.failure.network", defaultValue: "Coderouter is unreachable. Check your connection, then retry.")
        case .unavailable, .sessionChanging:
            return String(localized: "coderouter.failure.unknown", defaultValue: "Coderouter accounts didn't load. Retry in a moment.")
        }
    }

    /// The hint after a failed removal. Read-specific copy ("didn't load",
    /// "can't load") is replaced; the rest already fits.
    var removalMessage: String {
        switch self {
        case .outdated:
            return String(localized: "coderouter.failure.removeOutdated", defaultValue: "This Coderouter version can't remove team accounts. Update cmux, then retry.")
        case .unavailable, .sessionChanging:
            return String(localized: "coderouter.failure.remove", defaultValue: "Coderouter couldn't remove this account. Retry in a moment.")
        case .notInstalled, .signInRequired, .notMember, .planRequired, .unreachable:
            return message
        }
    }

    /// The hint after New Account setup fails. Read-specific copy ("didn't
    /// load", "can't load") is replaced with setup guidance.
    var addMessage: String {
        switch self {
        case .outdated:
            return String(localized: "coderouter.failure.addOutdated", defaultValue: "This Coderouter version can't add team accounts. Update cmux, then retry.")
        case .unavailable, .sessionChanging:
            return String(localized: "coderouter.failure.add", defaultValue: "Coderouter couldn't start account setup. Retry in a moment.")
        case .notInstalled, .signInRequired, .notMember, .planRequired, .unreachable:
            return message
        }
    }

    var errorDescription: String? { message }

    /// Classifies a CLI failure from its stderr (`coderouter: <message>`),
    /// whose HTTP suffixes and phrases are stable in coderouter 0.3.x.
    static func classify(_ error: Error) -> CoderouterCLIFailure {
        if let failure = error as? CoderouterCLIFailure { return failure }
        let failure = error as NSError
        guard failure.domain == "CoderouterCLI" else { return .unavailable }
        let message = failure.localizedDescription.lowercased()
        func mentions(_ phrases: String...) -> Bool { phrases.contains { message.contains($0) } }
        if message.hasPrefix("coderouter: usage:") && !message.contains("--team") {
            return .outdated
        }
        if mentions("[http 401]", "not signed in", "authorization expired", "session expired") {
            return .signInRequired
        }
        if mentions("[http 402]", "requires cmux pro") {
            return .planRequired
        }
        if mentions("[http 403]", "does not have permission", "was not found", "not mapped") {
            return .notMember
        }
        if mentions("timed out", "could not connect", "could not send the request", "network request failed", "temporarily", "[http 429]", "[http 5") {
            return .unreachable
        }
        return .unavailable
    }
}

/// Reads the selected team's CodeRouter accounts with the CLI's team-scoped
/// commands. CodeRouter's organization catalog is keyed by the Stack team UUID,
/// so `--team <id>` reaches it directly. Every caller supplies `run`, normally
/// from ``CoderouterAppCLISession``, so the sidebar always acts as the cmux
/// app's signed-in account and never as the CLI's own saved sign-in.
enum CoderouterCLIAccountReader {
    typealias Run = @Sendable (_ arguments: [String]) async throws -> Data

    struct Snapshot {
        let organizationID: String
        let accounts: [CloudTreeNode.CoderouterAccount]
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "coderouter-accounts")

#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    static func accounts(
        for cmuxTeamID: String?,
        name cmuxTeamName: String?,
        run: Run
    ) async throws -> [CloudTreeNode.CoderouterAccount] {
        let snapshot = try await snapshot(for: cmuxTeamID, name: cmuxTeamName, run: run)
        return snapshot.accounts
    }

    /// Reads the selected team's CodeRouter organization and account rows in
    /// one operation. The organization ID is retained by the sidebar so an
    /// account created from a team row can carry an explicit destination.
    /// Failures are ``CoderouterCLIFailure`` values.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    static func snapshot(
        for cmuxTeamID: String?,
        name cmuxTeamName: String?,
        run: Run
    ) async throws -> Snapshot {
        try Task.checkCancellation()
        guard let teamID = normalizedID(cmuxTeamID) else {
            throw CoderouterCLIFailure.notMember
        }
        do {
            guard let organizationID = try await resolvedOrganizationID(
                for: teamID,
                name: cmuxTeamName,
                run: run
            ) else {
                logger.error("No CodeRouter organization matched cmux team ID \(teamID, privacy: .public), name \(String(describing: cmuxTeamName), privacy: .public)")
                throw CoderouterCLIFailure.notMember
            }
            try Task.checkCancellation()
            let payload = try await readAccounts(arguments: ["accounts", "--json", "--team", organizationID], run: run)
            return try verifiedSnapshot(payload, organizationID: organizationID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CoderouterCLIFailure.classify(error)
        }
    }

    private static func verifiedSnapshot(
        _ payload: (organizationID: String?, accounts: [CloudTreeNode.CoderouterAccount]),
        organizationID: String
    ) throws -> Snapshot {
        guard payload.organizationID == organizationID else {
            logger.error("CodeRouter accounts were for org ID \(payload.organizationID ?? "<nil>", privacy: .public), expected \(organizationID, privacy: .public)")
            throw CoderouterCLIFailure.unavailable
        }
        logger.info("Loaded \(payload.accounts.count, privacy: .public) CodeRouter accounts for org ID \(organizationID, privacy: .public)")
        return Snapshot(organizationID: organizationID, accounts: payload.accounts)
    }

    private static func resolvedOrganizationID(
        for cmuxTeamID: String,
        name cmuxTeamName: String?,
        run: Run
    ) async throws -> String? {
        if UUID(uuidString: cmuxTeamID) != nil {
            return cmuxTeamID
        }
        return try await matchingOrganizationID(for: cmuxTeamID, name: cmuxTeamName, run: run)
    }

    /// Removes one account from the selected team. The CLI already reads the
    /// account list to select the provider, so no sidebar preflight is needed.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    static func remove(
        accountID: String,
        for cmuxTeamID: String?,
        name cmuxTeamName: String?,
        run: Run
    ) async throws {
        try Task.checkCancellation()
        guard UUID(uuidString: accountID) != nil else {
            throw accountError("That coderouter account ID is not valid.")
        }
        guard let teamID = normalizedID(cmuxTeamID) else {
            throw CoderouterCLIFailure.notMember
        }
        do {
            guard let organizationID = try await resolvedOrganizationID(
                for: teamID,
                name: cmuxTeamName,
                run: run
            ) else {
                throw CoderouterCLIFailure.notMember
            }
            _ = try await run(["remove", accountID, "--yes", "--team", organizationID])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CoderouterCLIFailure.classify(error)
        }
        logger.info("Removed CodeRouter account \(accountID, privacy: .public)")
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

    /// The share of the account's current rate-limit window still unused, the
    /// "93% left" `cr accounts` prints. Nil when the provider reports no window.
    private static func remainingPercent(usage: Any?) -> Int? {
        guard let usage = usage as? [String: Any],
              let rateLimit = usage["rate_limit"] as? [String: Any],
              let window = rateLimit["primary_window"] as? [String: Any],
              let used = (window["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        return min(100, max(0, Int((100 - used).rounded())))
    }

    /// Legacy mapping for a team ID that is not a Stack UUID. An exact ID on
    /// any catalog line wins, wherever it appears; only then is the team name
    /// compared, and a name shared by more than one organization is an error
    /// rather than an arbitrary pick. A missing name never blocks an ID match.
    private static func matchingOrganizationID(for cmuxTeamID: String, name cmuxTeamName: String?, run: Run) async throws -> String? {
        let output = try await run(["org", "list"])
        return try organizationID(
            matching: cmuxTeamID,
            name: cmuxTeamName,
            inCatalog: String(decoding: output, as: UTF8.self)
        )
    }

    /// The pure part of ``matchingOrganizationID(for:name:run:)``: `org list`
    /// prints one organization per line, its ID in the last column.
    static func organizationID(matching cmuxTeamID: String, name cmuxTeamName: String?, inCatalog catalog: String) throws -> String? {
        let organizations = catalog.split(whereSeparator: \.isNewline).compactMap { rawLine -> (id: String, name: String)? in
            let tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let candidateID = tokens.last,
                  UUID(uuidString: String(candidateID)) != nil || String(candidateID) == cmuxTeamID else { return nil }
            let candidateName = tokens.dropLast().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            return (String(candidateID), normalized(candidateName))
        }
        if let exact = organizations.first(where: { $0.id == cmuxTeamID }) { return exact.id }
        guard let cmuxTeamName = normalizedID(cmuxTeamName) else { return nil }
        let wanted = normalized(cmuxTeamName)
        let matches = organizations.filter { $0.name == wanted }
        guard matches.count <= 1 else {
            throw accountError("More than one CodeRouter organization matches the selected team.")
        }
        return matches.first?.id
    }

    private static func normalizedID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
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
    /// the app-bundled core (release, nightly and dev builds ship the tested
    /// version), then PATH (`coderouter`, then `cr`), then the installer's bin
    /// directory. The later candidates only matter for a bundle without one.
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

    /// Runs a CLI while draining stdout and stderr concurrently. Waiting for
    /// termination before reading either pipe deadlocks once a chatty command
    /// fills the kernel pipe buffer (the old sidebar reader did exactly that).
    /// This remains internal so the large-output behavior can be covered without
    /// depending on a real CodeRouter installation.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
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
            stdoutWriter: output.fileHandleForWriting,
            stderrWriter: error.fileHandleForWriting
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
                        cancellation.cancel()
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

        // `Pipe` keeps the parent's writer handles alive independently of the
        // child. Close them after the child exits so the drain tasks observe
        // EOF and the refresh can finish. The cancellation path closes the
        // same handles when a read is interrupted.
        cancellation.closeWriters()
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

/// The process and writer handles captured by the cancellation handler. Killing
/// the child closes its copies of both writers, and closing the parent's writer
/// handles also unblocks the drain tasks if Process.run() never succeeds. The
/// readers stay owned by their drain tasks for their entire lifetime.
private final class CoderouterProcessCancellation: @unchecked Sendable {
    private let process: Process
    private let stdoutWriter: FileHandle
    private let stderrWriter: FileHandle
    private let writerLock = NSLock()
    private var writersClosed = false

    init(process: Process, stdoutWriter: FileHandle, stderrWriter: FileHandle) {
        self.process = process
        self.stdoutWriter = stdoutWriter
        self.stderrWriter = stderrWriter
    }

    func cancel() {
        let identifier = process.processIdentifier
        if process.isRunning, identifier > 1 {
            process.terminate()
            if process.isRunning {
                _ = Darwin.kill(identifier, SIGKILL)
            }
        }
        closeWriters()
    }

    func closeWriters() {
        writerLock.lock()
        defer { writerLock.unlock() }
        guard !writersClosed else { return }
        writersClosed = true
        try? stdoutWriter.close()
        try? stderrWriter.close()
    }
}
