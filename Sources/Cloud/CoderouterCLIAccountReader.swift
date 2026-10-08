import Darwin
import Foundation
import OSLog

/// How a CodeRouter command is pinned to the selected team without relying on
/// the CLI's shared, persisted active organization.
enum CoderouterTeamScope: Equatable, Sendable {
    /// The CLI reports `team-override`: `CODEROUTER_TEAM_ID` scopes each
    /// invocation. No organization catalog read or switch is ever needed.
    case teamOverride
    /// The CLI accepts `--team <id>` on `accounts`, `remove`, and `add`.
    case teamOption
    /// Older CLIs: `org switch` plus the command, inside a private copy of the
    /// config so the user's terminals never see the switch.
    case isolatedConfiguration
}

/// Reads the same CodeRouter Cloud account view shown by `cmux cr accounts`.
/// CodeRouter's organization catalog is keyed by the Stack team UUID. Newer
/// CLI versions accept that ID on the account read, so a sidebar refresh does
/// not need to mutate the user's active organization.
enum CoderouterCLIAccountReader {
    typealias Run = @Sendable (_ arguments: [String]) async throws -> Data

    /// The CodeRouter CLI as the reader sees it: one command runner that can
    /// scope a single invocation to a team, and whether the CLI honors that
    /// scope. Tests replace both; production resolves the same binary as
    /// `cmux cr` and asks it once per binary version.
    struct CLI: Sendable {
        /// Runs one command. A non-nil team ID is passed as
        /// `CODEROUTER_TEAM_ID` for that invocation only.
        let run: @Sendable (_ arguments: [String], _ teamID: String?) async throws -> Data
        let supportsTeamOverride: @Sendable () async -> Bool

        /// The pre-`team-override` runner used by callers that only inject
        /// argument-level behavior.
        static func legacy(_ run: @escaping Run) -> CLI {
            CLI(run: { arguments, _ in try await run(arguments) }, supportsTeamOverride: { false })
        }

        static let live = CLI(
            run: { arguments, teamID in
                // Only the sidebar decides the team: an override inherited
                // from the app's own launch environment is never forwarded.
                var environment = ProcessInfo.processInfo.environment
                environment[CoderouterTeamEnvironment.variable] = teamID
                return try await CoderouterCLIAccountReader.runCLI(arguments, environment: environment)
            },
            supportsTeamOverride: { await CoderouterCLIAccountReader.liveSupportsTeamOverride() }
        )
    }

    struct Snapshot {
        let organizationID: String
        let accounts: [CloudTreeNode.CoderouterAccount]
        let scope: CoderouterTeamScope
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "coderouter-accounts")

    static func accounts(
        for cmuxTeamID: String?,
        name cmuxTeamName: String?,
        run: Run? = nil
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
        run: Run? = nil,
        cli injectedCLI: CLI? = nil
    ) async throws -> Snapshot {
        try Task.checkCancellation()
        let cli = injectedCLI ?? run.map { CLI.legacy($0) } ?? .live
        guard let teamID = CoderouterTeamEnvironment.normalizedTeamID(cmuxTeamID) else {
            throw accountError("The selected cmux team is not mapped to a coderouter organization.")
        }

        // A CLI with `team-override` takes the cmux team ID (which is the
        // CodeRouter organization ID) for this invocation only: no catalog
        // read, no `org switch`, and no shared state to race with. Only a
        // Stack team UUID is an organization ID; anything else keeps the
        // legacy mapping below.
        if UUID(uuidString: teamID) != nil, await cli.supportsTeamOverride() {
            try Task.checkCancellation()
            let payload = try await readAccounts(arguments: ["accounts", "--json"]) { arguments in
                try await cli.run(arguments, teamID)
            }
            return try verifiedSnapshot(payload, organizationID: teamID, scope: .teamOverride)
        }

        let invoke: Run = { arguments in try await cli.run(arguments, nil) }
        // Injected runners (tests) replace the isolated-config sequence too.
        let injectedRun: Run? = injectedCLI != nil || run != nil ? invoke : nil
        guard let organizationID = try await resolvedOrganizationID(
            for: teamID,
            name: cmuxTeamName,
            knownOrganizationID: knownOrganizationID,
            run: invoke
        ) else {
            logger.error("No CodeRouter organization matched cmux team ID \(teamID, privacy: .public), name \(String(describing: cmuxTeamName), privacy: .public)")
            throw accountError("The selected cmux team is not mapped to a coderouter organization.")
        }

        // Prefer the team-scoped read. It sends the selected organization in the
        // request and leaves the terminal's shared active organization untouched.
        try Task.checkCancellation()
        let payload: (organizationID: String?, accounts: [CloudTreeNode.CoderouterAccount])
        let scope: CoderouterTeamScope
        do {
            payload = try await readAccounts(arguments: ["accounts", "--json", "--team", organizationID], run: invoke)
            scope = .teamOption
        } catch {
            // CodeRouter 0.3.15 and earlier predate `accounts --team`. The app
            // bundles 0.3.16, but `resolvedExecutable` can still pick an older
            // CLI from PATH or the installer, so keep this fallback.
            guard isUnsupportedTeamOption(error, command: "accounts") else { throw error }
            logger.info("Using an isolated CodeRouter configuration for the legacy CLI")
            payload = try await withLegacyCLI(run: injectedRun) { legacyRun in
                try Task.checkCancellation()
                _ = try await legacyRun(["org", "switch", organizationID])
                try Task.checkCancellation()
                return try await readAccounts(arguments: ["accounts", "--json"], run: legacyRun)
            }
            scope = .isolatedConfiguration
        }
        return try verifiedSnapshot(payload, organizationID: organizationID, scope: scope)
    }

    private static func verifiedSnapshot(
        _ payload: (organizationID: String?, accounts: [CloudTreeNode.CoderouterAccount]),
        organizationID: String,
        scope: CoderouterTeamScope
    ) throws -> Snapshot {
        guard payload.organizationID == organizationID else {
            logger.error("CodeRouter accounts were for org ID \(payload.organizationID ?? "<nil>", privacy: .public), expected \(organizationID, privacy: .public)")
            throw accountError("coderouter returned accounts for a different team.")
        }
        logger.info("Loaded \(payload.accounts.count, privacy: .public) CodeRouter accounts for org ID \(organizationID, privacy: .public)")
        return Snapshot(organizationID: organizationID, accounts: payload.accounts, scope: scope)
    }

    private static func resolvedOrganizationID(
        for cmuxTeamID: String,
        name cmuxTeamName: String?,
        knownOrganizationID: String?,
        run: Run
    ) async throws -> String? {
        if UUID(uuidString: cmuxTeamID) != nil {
            return cmuxTeamID
        }
        if let knownOrganizationID = CoderouterTeamEnvironment.normalizedTeamID(knownOrganizationID),
           UUID(uuidString: knownOrganizationID) != nil {
            return knownOrganizationID
        }
        return try await matchingOrganizationID(for: cmuxTeamID, name: cmuxTeamName, run: run)
    }

    /// Removes one account from the selected team. The CLI already reads the
    /// account list to select the provider, so no sidebar preflight is needed.
    static func remove(
        accountID: String,
        for cmuxTeamID: String?,
        name cmuxTeamName: String?,
        knownOrganizationID: String? = nil,
        run: Run? = nil,
        cli injectedCLI: CLI? = nil
    ) async throws {
        try Task.checkCancellation()
        guard UUID(uuidString: accountID) != nil else {
            throw accountError("That coderouter account ID is not valid.")
        }
        guard let teamID = CoderouterTeamEnvironment.normalizedTeamID(cmuxTeamID) else {
            throw accountError("The selected cmux team is not mapped to a coderouter organization.")
        }
        let cli = injectedCLI ?? run.map { CLI.legacy($0) } ?? .live
        if UUID(uuidString: teamID) != nil, await cli.supportsTeamOverride() {
            try Task.checkCancellation()
            _ = try await cli.run(["remove", accountID, "--yes"], teamID)
            logger.info("Removed CodeRouter account \(accountID, privacy: .public)")
            return
        }
        let invoke: Run = { arguments in try await cli.run(arguments, nil) }
        let injectedRun: Run? = injectedCLI != nil || run != nil ? invoke : nil
        guard let organizationID = try await resolvedOrganizationID(
            for: teamID,
            name: cmuxTeamName,
            knownOrganizationID: knownOrganizationID,
            run: invoke
        ) else {
            throw accountError("The selected cmux team is not mapped to a coderouter organization.")
        }
        do {
            _ = try await invoke(["remove", accountID, "--yes", "--team", organizationID])
        } catch {
            // Compatibility with the pre-team-scoped CLI. This legacy path is
            // only used when the direct command is not understood.
            guard isUnsupportedTeamOption(error, command: "remove") else { throw error }
            try await withLegacyCLI(run: injectedRun) { legacyRun in
                try Task.checkCancellation()
                _ = try await legacyRun(["org", "switch", organizationID])
                try Task.checkCancellation()
                _ = try await legacyRun(["remove", accountID, "--yes"])
            }
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

    /// The bundled pre-team-scoped CLI reports a command usage string that
    /// does not mention `--team`. A newer CLI can fail for auth, network, or
    /// membership reasons; those failures must be returned to the sidebar and
    /// must never mutate the user's shared active organization.
    private static func isUnsupportedTeamOption(_ error: Error, command: String) -> Bool {
        let failure = error as NSError
        guard failure.domain == "CoderouterCLI", failure.code == 1 else { return false }
        let usage = command == "accounts"
            ? "coderouter: usage: coderouter accounts [--watch | --json]"
            : "coderouter: usage: coderouter remove [account-id-or-label] [--yes]"
        return failure.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines) == usage
    }

    private static func withLegacyCLI<T>(run: Run?, body: (Run) async throws -> T) async throws -> T {
        if let run { return try await body(run) }
        var inherited = ProcessInfo.processInfo.environment
        inherited[CoderouterTeamEnvironment.variable] = nil
        return try await withIsolatedConfiguration(environment: inherited) { environment in
            try await body { arguments in
                try await runCLI(arguments, environment: environment)
            }
        }
    }

    /// Legacy CLI operations share a private config for their whole sequence.
    /// An intervening terminal `org switch` cannot redirect a read or removal.
    static func withIsolatedConfiguration<T>(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        body: ([String: String]) async throws -> T
    ) async throws -> T {
        let fileManager = FileManager.default
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let sourceRoot = environment["CODEROUTER_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support").path
        let directory = fileManager.temporaryDirectory.appendingPathComponent("cmux-coderouter-\(UUID().uuidString)")
        let configDirectory = directory.appendingPathComponent("coderouter")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: false)
        try fileManager.copyItem(
            at: URL(fileURLWithPath: sourceRoot).appendingPathComponent("coderouter/config.json"),
            to: configDirectory.appendingPathComponent("config.json")
        )
        var isolatedEnvironment = environment
        isolatedEnvironment["CODEROUTER_DATA_DIR"] = directory.path
        return try await body(isolatedEnvironment)
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
        guard let cmuxTeamName = CoderouterTeamEnvironment.normalizedTeamID(cmuxTeamName) else { return nil }
        let wanted = normalized(cmuxTeamName)
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

    private static let capabilityCache = CoderouterCLICapabilityCache()

    /// Whether the CLI the sidebar runs honors `CODEROUTER_TEAM_ID`. The answer
    /// is cached per binary path and modification date, so an app update or a
    /// reinstall of the PATH CLI is re-probed and nothing else is.
    private static func liveSupportsTeamOverride() async -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let executable = resolvedExecutable(environment: environment) else { return false }
        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: executable))?[.modificationDate] as? Date
        return await capabilityCache.supportsTeamOverride(
            key: .init(executable: executable, modificationDate: modificationDate)
        ) {
            do {
                let result = try await runProcess(
                    executable: executable,
                    arguments: ["capabilities", "--json"],
                    environment: environment.filter { key, _ in
                        !key.hasPrefix("CMUX_") && !key.hasPrefix("CMUXD_")
                    }
                )
                return CoderouterTeamEnvironment.supportsTeamOverride(capabilitiesJSON: result.stdout)
            } catch is CancellationError {
                return nil
            } catch {
                // A CLI without `capabilities` (or one that fails it) is an
                // older CLI; it keeps the argument-level fallbacks.
                return false
            }
        }
    }

    @Sendable private static func runCLI(_ arguments: [String]) async throws -> Data {
        try await runCLI(arguments, environment: ProcessInfo.processInfo.environment)
    }

    @Sendable private static func runCLI(_ arguments: [String], environment: [String: String]) async throws -> Data {
        guard let executable = resolvedExecutable(environment: environment) else {
            throw accountError("coderouter is not installed. Run cmux cr in a terminal to install it.")
        }
        // Same isolation as `cmux cr`: CodeRouter never sees cmux's CMUX_* context.
        let environment = environment.filter { key, _ in
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

/// Remembers which CodeRouter binaries honor `team-override`. Entries are
/// keyed by path and modification date; a probe that ends in cancellation
/// (`nil`) is not remembered, so the next refresh asks again.
final class CoderouterCLICapabilityCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let executable: String
        let modificationDate: Date?
    }

    private let lock = NSLock()
    private var entries: [Key: Bool] = [:]

    func supportsTeamOverride(
        key: Key,
        probe: @Sendable () async -> Bool?
    ) async -> Bool {
        if let cached = cachedValue(for: key) { return cached }
        guard let probed = await probe() else { return false }
        store(probed, for: key)
        return probed
    }

    private func cachedValue(for key: Key) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    private func store(_ value: Bool, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        // One binary path has one current version; drop stale versions.
        entries = entries.filter { $0.key.executable != key.executable }
        entries[key] = value
    }
}
