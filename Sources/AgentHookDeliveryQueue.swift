import Darwin
import Foundation
import OSLog
import SQLite3

nonisolated private let agentHookDeliveryLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "AgentHookDelivery"
)

/// Persists wrapper hooks before acknowledgement, then delivers them through
/// one bounded child-process lane.
actor AgentHookDeliveryQueue {
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let databaseURL: URL
    // SQLite serializes this FULLMUTEX connection. `enqueue` must remain
    // synchronous so the socket cannot acknowledge before the durable insert.
    nonisolated(unsafe) private let database: OpaquePointer?
    nonisolated private let databaseInitializationError: String?
    private let executableURLProvider: @Sendable () -> URL?
    private let processTimeout: TimeInterval
    private let terminationGrace: TimeInterval
    private let retryBaseDelay: TimeInterval
    private let retryMaximumDelay: TimeInterval
    private let deliveredReceiptRetention: TimeInterval

    private var drainTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var deliveredSinceReceiptCleanup = 0

    init(
        databaseURL: URL? = nil,
        executableURLProvider: @escaping @Sendable () -> URL? = {
            Bundle.main.resourceURL?.appendingPathComponent("bin/cmux", isDirectory: false)
        },
        processTimeout: TimeInterval = 15,
        terminationGrace: TimeInterval = 0.5,
        retryBaseDelay: TimeInterval = 0.25,
        retryMaximumDelay: TimeInterval = 300,
        deliveredReceiptRetention: TimeInterval = 86_400
    ) {
        let resolvedDatabaseURL = databaseURL ?? Self.defaultDatabaseURL()
        self.databaseURL = resolvedDatabaseURL
        self.executableURLProvider = executableURLProvider
        self.processTimeout = max(0.01, processTimeout)
        self.terminationGrace = max(0.01, terminationGrace)
        self.retryBaseDelay = max(0.01, retryBaseDelay)
        self.retryMaximumDelay = max(self.retryBaseDelay, retryMaximumDelay)
        self.deliveredReceiptRetention = max(60, deliveredReceiptRetention)

        do {
            self.database = try Self.openDatabase(at: resolvedDatabaseURL)
            self.databaseInitializationError = nil
        } catch {
            self.database = nil
            self.databaseInitializationError = error.localizedDescription
            agentHookDeliveryLogger.fault("Could not open delivery queue: \(error.localizedDescription, privacy: .private)")
        }

        // A previous app process may have exited after acceptance but before
        // delivery. Resume those durable rows as soon as this queue is created.
        Task { [weak self] in
            await self?.deliveryAvailable()
        }
    }

    deinit {
        drainTask?.cancel()
        retryTask?.cancel()
        if let database {
            sqlite3_close_v2(database)
        }
    }

    /// Durably inserts an event before the socket acknowledges it. Duplicate
    /// delivery IDs with identical contents are successful no-ops.
    nonisolated func enqueue(_ event: AgentHookDeliveryEvent) throws {
        guard let database else {
            throw Self.failure(
                databaseInitializationError ?? "Agent hook delivery database is unavailable.",
                code: 1
            )
        }
        let environmentData = try JSONSerialization.data(
            withJSONObject: event.environment,
            options: [.sortedKeys]
        )
        let now = Date().timeIntervalSince1970
        let insertSQL = """
        INSERT OR IGNORE INTO agent_hook_deliveries (
            delivery_id, content_digest, agent, subcommand, payload,
            socket_path, environment_json, accepted_at, next_attempt_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(database, insertSQL, -1, &statement, nil)
        guard status == SQLITE_OK else {
            throw Self.sqliteFailure(status, operation: "prepare durable insert")
        }
        defer { sqlite3_finalize(statement) }

        status = Self.bind(event.deliveryID, to: statement, at: 1)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind delivery ID") }
        status = Self.bind(event.contentDigest, to: statement, at: 2)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind digest") }
        status = Self.bind(event.agent, to: statement, at: 3)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind agent") }
        status = Self.bind(event.subcommand, to: statement, at: 4)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind subcommand") }
        status = Self.bind(event.payload, to: statement, at: 5)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind payload") }
        status = Self.bind(event.socketPath, to: statement, at: 6)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind socket path") }
        status = Self.bind(environmentData, to: statement, at: 7)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind environment") }
        status = sqlite3_bind_double(statement, 8, now)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind acceptance time") }
        status = sqlite3_bind_double(statement, 9, now)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind retry time") }
        status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            throw Self.sqliteFailure(status, operation: "persist accepted delivery")
        }

        let storedDigest = try Self.storedDigest(for: event.deliveryID, database: database)
        guard storedDigest == event.contentDigest else {
            throw Self.failure(
                "Delivery ID \(event.deliveryID) was reused for different hook contents.",
                code: 2
            )
        }

        agentHookDeliveryLogger.debug("Accepted hook \(event.deliveryID, privacy: .public)")
        Task { [weak self] in
            await self?.deliveryAvailable()
        }
    }

    /// Makes every undelivered row immediately eligible again. This is also a
    /// diagnostics seam for explicit recovery after an external dependency is fixed.
    func retryPendingDeliveries() throws {
        guard let database else {
            throw Self.failure(databaseInitializationError ?? "Delivery database is unavailable.", code: 3)
        }
        let status = sqlite3_exec(
            database,
            "UPDATE agent_hook_deliveries SET next_attempt_at = 0 WHERE delivered_at IS NULL;",
            nil,
            nil,
            nil
        )
        guard status == SQLITE_OK else {
            throw Self.sqliteFailure(status, operation: "retry pending deliveries")
        }
        deliveryAvailable()
    }

    /// Returns durable state for diagnostics without loading payloads into memory.
    func diagnosticStatus(for deliveryID: String) throws -> [String: String]? {
        guard let database else {
            throw Self.failure(databaseInitializationError ?? "Delivery database is unavailable.", code: 4)
        }
        let sql = """
        SELECT attempts, delivered_at, next_attempt_at, COALESCE(last_error, '')
        FROM agent_hook_deliveries WHERE delivery_id = ? LIMIT 1;
        """
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK else {
            throw Self.sqliteFailure(status, operation: "prepare delivery status")
        }
        defer { sqlite3_finalize(statement) }
        status = Self.bind(deliveryID, to: statement, at: 1)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind status ID") }
        status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else {
            throw Self.sqliteFailure(status, operation: "read delivery status")
        }

        let delivered = sqlite3_column_type(statement, 1) != SQLITE_NULL
        return [
            "state": delivered ? "delivered" : "pending",
            "attempts": String(sqlite3_column_int(statement, 0)),
            "next_attempt_at": String(sqlite3_column_double(statement, 2)),
            "last_error": Self.columnText(statement, at: 3) ?? "",
        ]
    }

    /// Waits for the active drain pass. A future backoff deadline is not an
    /// active pass, so callers can inspect durable pending state afterward.
    func waitUntilCurrentDrainFinishes() async {
        deliveryAvailable()
        while let drainTask {
            await drainTask.value
        }
    }

    private func deliveryAvailable() {
        retryTask?.cancel()
        retryTask = nil
        guard drainTask == nil, database != nil else { return }
        drainTask = Task { [weak self] in
            await self?.drainAvailableDeliveries()
        }
    }

    private func drainAvailableDeliveries() async {
        defer { drainTask = nil }
        guard let database else { return }

        while !Task.isCancelled {
            do {
                guard let delivery = try nextDueDelivery(database: database) else {
                    try deleteExpiredReceipts(database: database)
                    try scheduleNextRetry(database: database)
                    return
                }
                try markAttemptStarted(sequence: delivery.sequence, database: database)
                let result = await deliver(
                    agent: delivery.agent,
                    subcommand: delivery.subcommand,
                    payload: delivery.payload,
                    socketPath: delivery.socketPath,
                    environment: delivery.environment,
                    deliveryID: delivery.deliveryID
                )
                if result.succeeded {
                    try markDelivered(sequence: delivery.sequence, database: database)
                    deliveredSinceReceiptCleanup += 1
                    if deliveredSinceReceiptCleanup >= 128 {
                        try deleteExpiredReceipts(database: database)
                        deliveredSinceReceiptCleanup = 0
                    }
                    agentHookDeliveryLogger.debug("Delivered hook \(delivery.deliveryID, privacy: .public)")
                } else {
                    let attempt = delivery.attempts + 1
                    let delay = min(
                        retryMaximumDelay,
                        retryBaseDelay * pow(4, Double(min(attempt - 1, 8)))
                    )
                    let detail = result.error ?? "Unknown delivery failure"
                    try markFailed(
                        sequence: delivery.sequence,
                        nextAttemptAt: Date().timeIntervalSince1970 + delay,
                        error: detail,
                        database: database
                    )
                    agentHookDeliveryLogger.error(
                        "Hook \(delivery.deliveryID, privacy: .public) failed; retrying in \(delay, privacy: .public)s: \(detail, privacy: .private)"
                    )
                }
            } catch {
                agentHookDeliveryLogger.fault("Delivery queue drain failed: \(error.localizedDescription, privacy: .private)")
                scheduleQueueRecovery(after: retryBaseDelay)
                return
            }
        }
    }

    private func nextDueDelivery(database: OpaquePointer) throws -> (
        sequence: Int64,
        deliveryID: String,
        agent: String,
        subcommand: String,
        payload: Data,
        socketPath: String,
        environment: [String: String],
        attempts: Int
    )? {
        let sql = """
        SELECT sequence, delivery_id, agent, subcommand, payload, socket_path,
               environment_json, attempts
        FROM agent_hook_deliveries
        WHERE delivered_at IS NULL AND next_attempt_at <= ?
        ORDER BY sequence ASC LIMIT 1;
        """
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK else {
            throw Self.sqliteFailure(status, operation: "prepare next delivery")
        }
        defer { sqlite3_finalize(statement) }
        status = sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind delivery deadline") }
        status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW,
              let deliveryID = Self.columnText(statement, at: 1),
              let agent = Self.columnText(statement, at: 2),
              let subcommand = Self.columnText(statement, at: 3),
              let payload = Self.columnData(statement, at: 4),
              let socketPath = Self.columnText(statement, at: 5),
              let environmentData = Self.columnData(statement, at: 6),
              let environment = try JSONSerialization.jsonObject(with: environmentData) as? [String: String] else {
            throw Self.failure("Stored delivery row is malformed.", code: 5)
        }
        return (
            sequence: sqlite3_column_int64(statement, 0),
            deliveryID: deliveryID,
            agent: agent,
            subcommand: subcommand,
            payload: payload,
            socketPath: socketPath,
            environment: environment,
            attempts: Int(sqlite3_column_int(statement, 7))
        )
    }

    private func markAttemptStarted(sequence: Int64, database: OpaquePointer) throws {
        try executeUpdate(
            "UPDATE agent_hook_deliveries SET attempts = attempts + 1, last_attempt_at = ? WHERE sequence = ?;",
            timestamp: Date().timeIntervalSince1970,
            sequence: sequence,
            database: database,
            operation: "mark delivery attempt"
        )
    }

    private func markDelivered(sequence: Int64, database: OpaquePointer) throws {
        let sql = """
        UPDATE agent_hook_deliveries
        SET delivered_at = ?, next_attempt_at = 0, last_error = NULL,
            payload = X'', socket_path = '', environment_json = X'7B7D'
        WHERE sequence = ?;
        """
        try executeUpdate(
            sql,
            timestamp: Date().timeIntervalSince1970,
            sequence: sequence,
            database: database,
            operation: "mark delivery complete"
        )
    }

    private func markFailed(
        sequence: Int64,
        nextAttemptAt: TimeInterval,
        error: String,
        database: OpaquePointer
    ) throws {
        let sql = """
        UPDATE agent_hook_deliveries
        SET next_attempt_at = ?, last_error = ?
        WHERE sequence = ?;
        """
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK else {
            throw Self.sqliteFailure(status, operation: "prepare failed delivery update")
        }
        defer { sqlite3_finalize(statement) }
        status = sqlite3_bind_double(statement, 1, nextAttemptAt)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind retry time") }
        status = Self.bind(String(error.prefix(4_096)), to: statement, at: 2)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind delivery error") }
        status = sqlite3_bind_int64(statement, 3, sequence)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind failed sequence") }
        status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            throw Self.sqliteFailure(status, operation: "record failed delivery")
        }
    }

    private func executeUpdate(
        _ sql: String,
        timestamp: TimeInterval,
        sequence: Int64,
        database: OpaquePointer,
        operation: String
    ) throws {
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "prepare \(operation)") }
        defer { sqlite3_finalize(statement) }
        status = sqlite3_bind_double(statement, 1, timestamp)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind \(operation) time") }
        status = sqlite3_bind_int64(statement, 2, sequence)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind \(operation) sequence") }
        status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw Self.sqliteFailure(status, operation: operation) }
    }

    private func deleteExpiredReceipts(database: OpaquePointer) throws {
        let cutoff = Date().timeIntervalSince1970 - deliveredReceiptRetention
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(
            database,
            "DELETE FROM agent_hook_deliveries WHERE delivered_at IS NOT NULL AND delivered_at < ?;",
            -1,
            &statement,
            nil
        )
        guard status == SQLITE_OK else {
            throw Self.sqliteFailure(status, operation: "prepare receipt cleanup")
        }
        defer { sqlite3_finalize(statement) }
        status = sqlite3_bind_double(statement, 1, cutoff)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind receipt cutoff") }
        status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw Self.sqliteFailure(status, operation: "delete expired receipts") }
    }

    private func scheduleNextRetry(database: OpaquePointer) throws {
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(
            database,
            "SELECT MIN(next_attempt_at) FROM agent_hook_deliveries WHERE delivered_at IS NULL;",
            -1,
            &statement,
            nil
        )
        guard status == SQLITE_OK else {
            throw Self.sqliteFailure(status, operation: "prepare retry deadline")
        }
        defer { sqlite3_finalize(statement) }
        status = sqlite3_step(statement)
        guard status == SQLITE_ROW else { throw Self.sqliteFailure(status, operation: "read retry deadline") }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return }
        let deadline = sqlite3_column_double(statement, 0)
        scheduleQueueRecovery(after: max(0.01, deadline - Date().timeIntervalSince1970))
    }

    private func scheduleQueueRecovery(after delay: TimeInterval) {
        retryTask?.cancel()
        let boundedDelay = min(retryMaximumDelay, max(0.01, delay))
        retryTask = Task { [weak self] in
            do {
                // This is the queue's real retry deadline, not a polling sleep.
                try await ContinuousClock().sleep(for: .milliseconds(Int64(boundedDelay * 1_000)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.retryDeadlineReached()
        }
    }

    private func retryDeadlineReached() {
        retryTask = nil
        deliveryAvailable()
    }

    private func deliver(
        agent: String,
        subcommand: String,
        payload: Data,
        socketPath: String,
        environment eventEnvironment: [String: String],
        deliveryID: String
    ) async -> (succeeded: Bool, error: String?) {
        guard let executableURL = executableURLProvider(),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return (false, "Bundled cmux CLI is unavailable or not executable.")
        }

        let input: FileHandle
        let errorOutput: FileHandle
        do {
            input = try Self.anonymousFile(containing: payload, near: databaseURL)
            errorOutput = try Self.anonymousFile(containing: Data(), near: databaseURL)
        } catch {
            return (false, "Could not create file-backed child I/O: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--socket", socketPath,
            "hooks", agent, subcommand,
        ]
        let ambientEnvironment = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "PATH", "SHELL", "TMPDIR", "USER"] {
            if let value = ambientEnvironment[key] {
                environment[key] = value
            }
        }
        environment.merge(eventEnvironment, uniquingKeysWith: { _, eventValue in eventValue })
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = executableURL.path
        environment["CMUX_AGENT_HOOK_DELIVERY_ID"] = deliveryID
        environment.removeValue(forKey: "CMUX_SOCKET")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorOutput

        let terminations = AsyncStream<Int32> { continuation in
            process.terminationHandler = { terminatedProcess in
                continuation.yield(terminatedProcess.terminationStatus)
                continuation.finish()
            }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            return (false, "Could not launch bundled cmux CLI: \(error.localizedDescription)")
        }

        let outcome = await waitForExitOrTimeout(process: process, terminations: terminations)
        process.terminationHandler = nil
        let stderr = Self.readErrorOutput(errorOutput)
        if outcome.timedOut {
            return (false, "Bundled cmux CLI exceeded \(processTimeout)s.\(stderr)")
        }
        guard outcome.status == 0 else {
            return (false, "Bundled cmux CLI exited with status \(outcome.status).\(stderr)")
        }
        return (true, nil)
    }

    private func waitForExitOrTimeout(
        process: Process,
        terminations: AsyncStream<Int32>
    ) async -> (status: Int32, timedOut: Bool) {
        await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                for await status in terminations {
                    return status
                }
                return -1
            }
            let timeout = processTimeout
            group.addTask {
                do {
                    // This is the child deadline itself, not a polling sleep.
                    try await ContinuousClock().sleep(for: .milliseconds(Int64(timeout * 1_000)))
                    return nil
                } catch {
                    return -1
                }
            }

            guard let firstResult = await group.next() else {
                return (-1, false)
            }
            if let status = firstResult {
                group.cancelAll()
                return (status, false)
            }

            if process.isRunning {
                process.terminate()
            }
            do {
                // A short grace period lets the child clean up before SIGKILL.
                try await ContinuousClock().sleep(for: .milliseconds(Int64(terminationGrace * 1_000)))
            } catch {}
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }

            var exitStatus: Int32 = -1
            while let result = await group.next() {
                if let status = result {
                    exitStatus = status
                    break
                }
            }
            group.cancelAll()
            return (exitStatus, true)
        }
    }

    private nonisolated static func defaultDatabaseURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        return appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("agent-hook-delivery.sqlite3", isDirectory: false)
    }

    private nonisolated static func openDatabase(at url: URL) throws -> OpaquePointer {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var status = sqlite3_open_v2(url.path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw sqliteFailure(status, operation: "open delivery database")
        }

        sqlite3_busy_timeout(database, 250)
        let setupStatements = [
            "PRAGMA journal_mode = WAL;",
            "PRAGMA synchronous = FULL;",
            "PRAGMA wal_autocheckpoint = 1000;",
            """
            CREATE TABLE IF NOT EXISTS agent_hook_deliveries (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                delivery_id TEXT NOT NULL UNIQUE,
                content_digest BLOB NOT NULL,
                agent TEXT NOT NULL,
                subcommand TEXT NOT NULL,
                payload BLOB NOT NULL,
                socket_path TEXT NOT NULL,
                environment_json BLOB NOT NULL,
                accepted_at REAL NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_attempt_at REAL,
                next_attempt_at REAL NOT NULL,
                delivered_at REAL,
                last_error TEXT
            );
            """,
            """
            CREATE INDEX IF NOT EXISTS agent_hook_deliveries_due
            ON agent_hook_deliveries (delivered_at, next_attempt_at, sequence);
            """,
        ]
        for sql in setupStatements {
            status = sqlite3_exec(database, sql, nil, nil, nil)
            guard status == SQLITE_OK else {
                sqlite3_close_v2(database)
                throw sqliteFailure(status, operation: "initialize delivery database")
            }
        }
        Darwin.chmod(url.path, 0o600)
        return database
    }

    private nonisolated static func storedDigest(
        for deliveryID: String,
        database: OpaquePointer
    ) throws -> Data? {
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(
            database,
            "SELECT content_digest FROM agent_hook_deliveries WHERE delivery_id = ? LIMIT 1;",
            -1,
            &statement,
            nil
        )
        guard status == SQLITE_OK else {
            throw sqliteFailure(status, operation: "prepare duplicate check")
        }
        defer { sqlite3_finalize(statement) }
        status = bind(deliveryID, to: statement, at: 1)
        guard status == SQLITE_OK else { throw sqliteFailure(status, operation: "bind duplicate check") }
        status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw sqliteFailure(status, operation: "read duplicate check") }
        return columnData(statement, at: 0)
    }

    private nonisolated static func anonymousFile(containing data: Data, near databaseURL: URL) throws -> FileHandle {
        let directory = databaseURL.deletingLastPathComponent()
        var template = Array(directory.appendingPathComponent("agent-hook-io.XXXXXX").path.utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress)
        }
        guard descriptor >= 0 else {
            throw failure("mkstemp failed with errno \(errno).", code: 6)
        }
        Darwin.fchmod(descriptor, 0o600)
        template.withUnsafeBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                Darwin.unlink(baseAddress)
            }
        }

        var writeError: Int32?
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    writeError = errno
                    break
                }
                offset += count
            }
        }
        if let writeError {
            Darwin.close(descriptor)
            throw failure("Writing child I/O file failed with errno \(writeError).", code: 7)
        }
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            let seekError = errno
            Darwin.close(descriptor)
            throw failure("Seeking child I/O file failed with errno \(seekError).", code: 8)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private nonisolated static func readErrorOutput(_ file: FileHandle) -> String {
        do {
            try file.seek(toOffset: 0)
            guard let data = try file.read(upToCount: 4_096), !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            return " stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch {
            return ""
        }
    }

    private nonisolated static func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) -> Int32 {
        value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
        }
    }

    private nonisolated static func bind(_ value: Data, to statement: OpaquePointer?, at index: Int32) -> Int32 {
        if value.isEmpty {
            return sqlite3_bind_zeroblob(statement, index, 0)
        }
        return value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
    }

    private nonisolated static func columnText(_ statement: OpaquePointer?, at index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private nonisolated static func columnData(_ statement: OpaquePointer?, at index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private nonisolated static func sqliteFailure(_ status: Int32, operation: String) -> NSError {
        let message = sqlite3_errstr(status).map(String.init(cString:)) ?? "unknown SQLite error"
        return failure("Could not \(operation): \(message) (\(status)).", code: Int(status))
    }

    private nonisolated static func failure(_ message: String, code: Int) -> NSError {
        NSError(
            domain: "com.cmuxterm.agent-hook-delivery",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
