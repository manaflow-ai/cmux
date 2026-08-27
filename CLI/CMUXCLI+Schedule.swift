import Darwin
import Foundation

struct CMUXScheduledJob: Codable, Identifiable {
    enum State: String, Codable {
        case pending
        case paused
        case completed
        case failed
    }

    let id: String
    let name: String
    let fireAt: Date
    let surfaceID: String
    let text: String
    var state: State
    var lastRunAt: Date?
    var lastError: String?
}

struct CMUXScheduleStore {
    static var defaultURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("scheduled-jobs.json", isDirectory: false)
    }

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL = CMUXScheduleStore.defaultURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// Loads the atomically replaced schedule file.
    func load() throws -> [CMUXScheduledJob] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CMUXScheduledJob].self, from: data)
    }

    /// Saves jobs with private directory and file permissions.
    func save(_ jobs: [CMUXScheduledJob]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directoryURL.path
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(jobs)
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try data.write(to: temporaryURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: temporaryURL.path
        )
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    /// Serializes the complete read-modify-write cycle across CLI processes.
    func withLockedJobs<T>(_ body: (inout [CMUXScheduledJob]) throws -> T) throws -> T {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw CLIError(message: String(localized: "cli.schedule.error.lockFailed", defaultValue: "Unable to lock scheduled jobs."))
        }
        var lock = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = fcntl(descriptor, F_SETLK, &lock)
            Darwin.close(descriptor)
        }
        guard fcntl(descriptor, F_SETLKW, &lock) == 0 else {
            throw CLIError(message: String(localized: "cli.schedule.error.lockFailed", defaultValue: "Unable to lock scheduled jobs."))
        }
        var jobs = try load()
        let result = try body(&jobs)
        try save(jobs)
        return result
    }
}

private struct CMUXScheduleLaunchdClient {
    typealias LaunchctlRunner = ([String]) throws -> Void

    private static let labelPrefix = "com.cmuxterm.cmux.schedule."
    private let fileManager: FileManager
    private let launchAgentsDirectory: URL
    private let launchctlRunner: LaunchctlRunner
    private let now: () -> Date

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping () -> Date = Date.init,
        launchctlRunner: @escaping LaunchctlRunner = CMUXScheduleLaunchdClient.runLaunchctl
    ) {
        self.fileManager = fileManager
        self.launchAgentsDirectory = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.now = now
        self.launchctlRunner = launchctlRunner
    }

    func label(for jobID: String) -> String {
        Self.labelPrefix + jobID
    }

    func plistURL(for jobID: String) -> URL {
        launchAgentsDirectory
            .appendingPathComponent("\(label(for: jobID)).plist", isDirectory: false)
    }

    /// Installs a one-shot launchd agent; the run command removes it afterward.
    func install(job: CMUXScheduledJob, executablePath: String) throws {
        let plistURL = plistURL(for: job.id)
        let secondsUntilFire = max(1, Int(ceil(job.fireAt.timeIntervalSince(now()))))
        let plist: [String: Any] = [
            "Label": label(for: job.id),
            "ProgramArguments": [executablePath, "schedule", "run", job.id],
            "StartInterval": secondsUntilFire,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        let directoryURL = plistURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try data.write(to: plistURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: plistURL.path
        )
        try launchctlRunner(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    /// Removes the launchd registration and its local plist if present.
    func remove(jobID: String) {
        let plistURL = plistURL(for: jobID)
        try? launchctlRunner(["bootout", "gui/\(getuid())/\(label(for: jobID))"])
        try? fileManager.removeItem(at: plistURL)
    }

    private static func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw CLIError(message: String(localized: "cli.schedule.error.launchdFailed", defaultValue: "Unable to install the scheduled command."))
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let diagnostic = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let diagnostic, !diagnostic.isEmpty {
                cliDebugLog("schedule launchd failure: \(diagnostic)")
            }
            throw CLIError(
                message: String(localized: "cli.schedule.error.launchdFailed", defaultValue: "Unable to install the scheduled command.")
            )
        }
    }
}

extension CMUXCLI {
    func scheduleCommandDoesNotNeedSocket(_ commandArgs: [String]) -> Bool {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        return ["help", "list", "pause", "resume", "delete"].contains(subcommand)
    }

    func runScheduleCommand(
        commandArgs: [String],
        client: SocketClient?,
        jsonOutput: Bool,
        explicitPassword _: String?,
        socketPath _: String?
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let args = Array(commandArgs.dropFirst())
        let store = CMUXScheduleStore()
        let launchd = CMUXScheduleLaunchdClient()

        switch subcommand {
        case "help", "--help", "-h":
            print(scheduleUsage())

        case "list":
            guard args.isEmpty else {
                throw CLIError(message: scheduleLocalized("cli.schedule.error.listUsage", "Usage: cmux schedule list [--json]"))
            }
            try printScheduleList(try store.load(), jsonOutput: jsonOutput)

        case "create":
            guard let client else {
                throw CLIError(message: scheduleLocalized("cli.schedule.error.requiresApp", "cmux schedule create requires a running cmux app"))
            }
            try createScheduledJob(
                args: args,
                store: store,
                client: client,
                launchd: launchd,
                jsonOutput: jsonOutput
            )

        case "run":
            guard args.count == 1 else {
                throw CLIError(message: scheduleLocalized("cli.schedule.error.runUsage", "Usage: cmux schedule run <id>"))
            }
            guard let client else {
                try recordScheduledFailure(
                    id: args[0],
                    store: store,
                    launchd: launchd,
                    reason: scheduleLocalized("cli.schedule.error.appUnavailable", "cmux is not available to run the scheduled command")
                )
                throw CLIError(message: scheduleLocalized("cli.schedule.error.appUnavailable", "cmux is not available to run the scheduled command"))
            }
            try runScheduledJob(
                id: args[0],
                store: store,
                client: client,
                launchd: launchd,
                jsonOutput: jsonOutput
            )

        case "pause", "resume", "delete":
            guard args.count == 1 else {
                throw CLIError(
                    message: scheduleLocalized(
                        "cli.schedule.error.actionUsage",
                        "Usage: cmux schedule %1$@ <id>",
                        subcommand
                    )
                )
            }
            try updateScheduledJob(
                id: args[0],
                action: subcommand,
                store: store,
                launchd: launchd,
                jsonOutput: jsonOutput
            )

        default:
            throw CLIError(
                message: scheduleLocalized(
                    "cli.schedule.error.unknownSubcommand",
                    "Unknown schedule subcommand '%1$@'. Run 'cmux schedule --help'.",
                    subcommand
                )
            )
        }
    }

    private func createScheduledJob(
        args: [String],
        store: CMUXScheduleStore,
        client: SocketClient,
        launchd: CMUXScheduleLaunchdClient,
        jsonOutput: Bool
    ) throws {
        let (name, rem0) = parseOption(args, name: "--name")
        let (at, rem1) = parseOption(rem0, name: "--at")
        let (after, rem2) = parseOption(rem1, name: "--after")
        let (surfaceArg, rem3) = parseOption(rem2, name: "--surface")
        let (workspaceArg, rem4) = parseOption(rem3, name: "--workspace")
        let (windowArg, rem5) = parseOption(rem4, name: "--window")
        let rawText = rem5.dropFirst(rem5.first == "--" ? 1 : 0).joined(separator: " ")
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw CLIError(message: scheduleLocalized("cli.schedule.error.missingName", "cmux schedule create requires --name <name>"))
        }
        guard (at == nil) != (after == nil) else {
            throw CLIError(message: scheduleLocalized("cli.schedule.error.oneTime", "cmux schedule create requires exactly one of --at or --after"))
        }
        guard let surfaceArg, !surfaceArg.isEmpty else {
            throw CLIError(message: scheduleLocalized("cli.schedule.error.missingSurface", "cmux schedule create requires --surface <id|ref|index>"))
        }
        guard !rawText.isEmpty else {
            throw CLIError(message: scheduleLocalized("cli.schedule.error.missingText", "cmux schedule create requires command text after --"))
        }

        let fireAt: Date
        if let at {
            guard let parsed = Self.parseScheduleDate(at) else {
                throw CLIError(
                    message: scheduleLocalized(
                        "cli.schedule.error.invalidDate",
                        "--at must be an ISO-8601 date, for example 2026-08-24T09:00:00+08:00"
                    )
                )
            }
            fireAt = parsed
        } else {
            fireAt = Date().addingTimeInterval(try Self.scheduleDelay(after!))
        }
        guard fireAt > Date() else {
            throw CLIError(message: scheduleLocalized("cli.schedule.error.pastDate", "scheduled time must be in the future"))
        }

        let windowID = try normalizeWindowHandle(windowArg, client: client)
        let workspaceID = try normalizeWorkspaceHandle(
            workspaceArg,
            client: client,
            windowHandle: windowID
        )
        let surfaceID = try resolveScheduledSurface(
            surfaceArg,
            client: client,
            workspaceID: workspaceID,
            windowID: windowID
        )
        let job = CMUXScheduledJob(
            id: UUID().uuidString.lowercased(),
            name: name,
            fireAt: fireAt,
            surfaceID: surfaceID,
            text: unescapeScheduleText(rawText),
            state: .pending,
            lastRunAt: nil,
            lastError: nil
        )
        do {
            try store.withLockedJobs { jobs in
                guard !jobs.contains(where: { $0.name == name && $0.state == .pending }) else {
                    throw CLIError(
                        message: scheduleLocalized(
                            "cli.schedule.error.duplicateName",
                            "a pending schedule named '%1$@' already exists",
                            name
                        )
                    )
                }
                jobs.append(job)
                do {
                    try launchd.install(
                        job: job,
                        executablePath: try Self.currentExecutablePath()
                    )
                } catch {
                    jobs.removeAll { $0.id == job.id }
                    throw error
                }
            }
        } catch {
            launchd.remove(jobID: job.id)
            throw error
        }

        if jsonOutput {
            print(jsonString(scheduleSummary(job)))
        } else {
            print(
                scheduleLocalized(
                    "cli.schedule.output.created",
                    "OK %1$@ at %2$@",
                    job.id,
                    Self.scheduleDateFormatter.string(from: job.fireAt)
                )
            )
        }
    }

    private func runScheduledJob(
        id: String,
        store: CMUXScheduleStore,
        client: SocketClient,
        launchd: CMUXScheduleLaunchdClient,
        jsonOutput: Bool
    ) throws {
        var completedSummary: [String: Any]?
        var sendPayload: [String: Any]?
        var sendFailed = false
        try store.withLockedJobs { jobs in
            guard let index = jobs.firstIndex(where: { $0.id == id }) else {
                throw CLIError(message: scheduleLocalized("cli.schedule.error.notFound", "schedule not found: %1$@", id))
            }
            guard jobs[index].state == .pending else { return }
            let job = jobs[index]
            do {
                let payload = try client.sendV2(
                    method: "surface.send_text",
                    params: ["surface_id": job.surfaceID, "text": job.text]
                )
                jobs[index].state = .completed
                jobs[index].lastRunAt = Date()
                jobs[index].lastError = nil
                completedSummary = scheduleSummary(jobs[index])
                sendPayload = payload
            } catch {
                jobs[index].state = .failed
                jobs[index].lastRunAt = Date()
                jobs[index].lastError = scheduleLocalized(
                    "cli.schedule.error.sendFailed",
                    "The scheduled command could not be sent."
                )
                sendFailed = true
            }
        }
        launchd.remove(jobID: id)
        guard let completedSummary else {
            if sendFailed {
                throw CLIError(message: scheduleLocalized("cli.schedule.error.sendFailed", "The scheduled command could not be sent."))
            }
            return
        }
        if jsonOutput {
            print(jsonString(["job": completedSummary, "send": sendPayload ?? [:]]))
        } else {
            print(scheduleLocalized("cli.schedule.output.completed", "OK %1$@", id))
        }
    }

    private func recordScheduledFailure(
        id: String,
        store: CMUXScheduleStore,
        launchd: CMUXScheduleLaunchdClient,
        reason: String
    ) throws {
        try store.withLockedJobs { jobs in
            guard let index = jobs.firstIndex(where: { $0.id == id }) else {
                throw CLIError(message: scheduleLocalized("cli.schedule.error.notFound", "schedule not found: %1$@", id))
            }
            guard jobs[index].state == .pending else { return }
            jobs[index].state = .failed
            jobs[index].lastRunAt = Date()
            jobs[index].lastError = reason
        }
        launchd.remove(jobID: id)
    }

    private func updateScheduledJob(
        id: String,
        action: String,
        store: CMUXScheduleStore,
        launchd: CMUXScheduleLaunchdClient,
        jsonOutput: Bool
    ) throws {
        var result: [String: Any]?
        do {
            try store.withLockedJobs { jobs in
                guard let index = jobs.firstIndex(where: { $0.id == id }) else {
                    throw CLIError(message: scheduleLocalized("cli.schedule.error.notFound", "schedule not found: %1$@", id))
                }
                switch action {
                case "pause":
                    guard jobs[index].state == .pending else {
                        throw CLIError(message: scheduleLocalized("cli.schedule.error.pauseState", "only pending schedules can be paused"))
                    }
                    jobs[index].state = .paused
                    launchd.remove(jobID: id)
                case "resume":
                    guard jobs[index].state == .paused else {
                        throw CLIError(message: scheduleLocalized("cli.schedule.error.resumeState", "only paused schedules can be resumed"))
                    }
                    try launchd.install(
                        job: jobs[index],
                        executablePath: try Self.currentExecutablePath()
                    )
                    jobs[index].state = .pending
                case "delete":
                    jobs.remove(at: index)
                    launchd.remove(jobID: id)
                default:
                    throw CLIError(message: scheduleLocalized("cli.schedule.error.unknownAction", "unknown schedule action: %1$@", action))
                }
                result = jobs.first(where: { $0.id == id }).map(scheduleSummary) ?? ["id": id, "deleted": true]
            }
        } catch {
            if action == "resume" { launchd.remove(jobID: id) }
            throw error
        }
        if jsonOutput {
            print(jsonString(result ?? ["id": id]))
        } else {
            print(scheduleLocalized("cli.schedule.output.action", "OK %1$@ %2$@", action, id))
        }
    }

    private func resolveScheduledSurface(
        _ raw: String,
        client: SocketClient,
        workspaceID: String?,
        windowID: String?
    ) throws -> String {
        var params: [String: Any] = [:]
        if let workspaceID { params["workspace_id"] = workspaceID }
        if let windowID { params["window_id"] = windowID }
        let payload = try client.sendV2(method: "surface.list", params: params)
        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
        let requestedIndex = Int(raw)
        for surface in surfaces {
            let matchesRaw = (surface["ref"] as? String) == raw || (surface["id"] as? String) == raw
            let matchesIndex = requestedIndex.map { (surface["index"] as? NSNumber)?.intValue == $0 } ?? false
            if matchesRaw || matchesIndex, let id = surface["id"] as? String, !id.isEmpty {
                return id
            }
        }
        throw CLIError(message: scheduleLocalized("cli.schedule.error.surfaceNotFound", "surface not found: %1$@", raw))
    }

    private func printScheduleList(_ jobs: [CMUXScheduledJob], jsonOutput: Bool) throws {
        if jsonOutput {
            print(jsonString(["jobs": jobs.map(scheduleSummary)]))
            return
        }
        if jobs.isEmpty {
            print(scheduleLocalized("cli.schedule.output.empty", "No scheduled jobs."))
            return
        }
        for job in jobs.sorted(by: { $0.fireAt < $1.fireAt }) {
            print(
                scheduleLocalized(
                    "cli.schedule.output.row",
                    "%1$@  %2$@  %3$@  %4$@",
                    job.id,
                    job.state.rawValue,
                    Self.scheduleDateFormatter.string(from: job.fireAt),
                    job.name
                )
            )
        }
    }

    private func scheduleSummary(_ job: CMUXScheduledJob) -> [String: Any] {
        var summary: [String: Any] = [
            "id": job.id,
            "name": job.name,
            "at": Self.scheduleDateFormatter.string(from: job.fireAt),
            "surface_id": job.surfaceID,
            "state": job.state.rawValue,
            "text_length": job.text.count,
        ]
        if let lastRunAt = job.lastRunAt {
            summary["last_run_at"] = Self.scheduleDateFormatter.string(from: lastRunAt)
        }
        if let lastError = job.lastError {
            summary["last_error"] = lastError
        }
        return summary
    }

    private func unescapeScheduleText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\n", with: "\r")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    private static func scheduleDelay(_ raw: String) throws -> TimeInterval {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let suffixes: [(String, Double)] = [("d", 86_400), ("h", 3_600), ("m", 60), ("s", 1)]
        guard let suffix = suffixes.first(where: { normalized.hasSuffix($0.0) }),
              let value = Double(normalized.dropLast(suffix.0.count)),
              value > 0 else {
            throw CLIError(
                message: String(
                    localized: "cli.schedule.error.invalidDelay",
                    defaultValue: "--after must be a positive duration such as 30s, 5m, or 2h"
                )
            )
        }
        return value * suffix.1
    }

    private static func currentExecutablePath() throws -> String {
        guard let executableURL = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw CLIError(message: String(localized: "cli.schedule.error.executablePath", defaultValue: "Unable to locate the cmux executable."))
        }
        return executableURL.path
    }

    private static let scheduleDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let scheduleDateFormatterWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseScheduleDate(_ raw: String) -> Date? {
        scheduleDateFormatter.date(from: raw)
            ?? scheduleDateFormatterWithoutFractionalSeconds.date(from: raw)
    }

    private func scheduleLocalized(_ key: StaticString, _ defaultValue: String, _ arguments: CVarArg...) -> String {
        let localized = String(localized: key, defaultValue: "\(defaultValue)")
        return arguments.isEmpty ? localized : String(format: localized, arguments: arguments)
    }

    func scheduleUsage() -> String {
        String(localized: "cli.schedule.usage", defaultValue: """
        Usage: cmux schedule <list|create|run|pause|resume|delete>

        Schedule one command for a specific terminal surface.

        Subcommands:
          create --name <name> (--at <ISO-8601> | --after <duration>) \
            --surface <id|ref|index> -- <text>
          list
          run <id>          Internal entry point; sends when due
          pause <id>
          resume <id>
          delete <id>

        The first slice is one-shot only. Recurring schedules, agent dispatch,
        and UI management are intentionally not included.

        Examples:
          cmux schedule create --name nightly --after 30m --surface surface:2 -- "make test\\n"
          cmux schedule create --name report --at 2026-08-24T09:00:00+08:00 --surface surface:2 -- "echo ready\\n"
          cmux schedule list
        """)
    }
}
