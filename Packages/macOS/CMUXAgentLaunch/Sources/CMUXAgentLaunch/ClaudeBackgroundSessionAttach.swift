import Darwin
import Foundation

/// A terminal that was showing a Claude Code background session through
/// `claude attach <id|name>`.
///
/// Claude's daemon (`claude bg-pty-host` / `claude bg-spare`) owns the session
/// itself; the pane only hosts a viewer. Restoring such a pane must reattach
/// the viewer, never start a second writer with `claude --resume`.
public struct ClaudeBackgroundSessionViewer: Codable, Equatable, Sendable {
    /// The id, short job id, or name the viewer was attached with.
    public var reference: String
    /// The viewer's `claude` executable, optionally preceded by `env`.
    public var launchArguments: [String]
    /// The attach-relevant environment of the viewer process.
    public var environment: [String: String]?

    public init(reference: String, launchArguments: [String], environment: [String: String]?) {
        self.reference = reference
        self.launchArguments = launchArguments
        self.environment = environment
    }
}

/// One live background session listed in Claude's per-config session registry.
public struct ClaudeBackgroundSessionRegistration: Equatable, Sendable {
    public let processID: Int
    public let sessionID: String
    /// Claude's short job id (for example `884a7be7`), shown by `claude agents`.
    public let jobID: String?
    public let name: String?
    /// The owner's start time as Claude recorded it (UTC, ctime layout).
    public let processStart: String?
    /// The PID namespace the record was written in (`darwin` on macOS).
    public let pidDomain: String?

    public init(
        processID: Int,
        sessionID: String,
        jobID: String?,
        name: String?,
        processStart: String? = nil,
        pidDomain: String? = nil
    ) {
        self.processID = processID
        self.sessionID = sessionID
        self.jobID = jobID
        self.name = name
        self.processStart = processStart
        self.pidDomain = pidDomain
    }

    /// The target `claude attach` accepts: the job id `claude agents` prints,
    /// falling back to the full session id.
    public var attachTarget: String {
        jobID ?? sessionID
    }
}

/// Reads Claude's session registry (`$CLAUDE_CONFIG_DIR/sessions/<pid>.json`),
/// the same per-process records `claude agents --json --all` lists.
///
/// Reading the records directly keeps the restore decision synchronous and
/// avoids spawning `claude` once per restored pane.
public struct ClaudeBackgroundSessionRegistry: Sendable {
    private let sessionsDirectory: String
    private let contentsOfDirectory: @Sendable (String) -> [String]?
    private let readFile: @Sendable (String) -> Data?
    private let processMatchesRecord: @Sendable (ClaudeBackgroundSessionRegistration) -> Bool

    public init(
        configDirectory: String,
        contentsOfDirectory: @escaping @Sendable (String) -> [String]? = {
            try? FileManager.default.contentsOfDirectory(atPath: $0)
        },
        readFile: @escaping @Sendable (String) -> Data? = {
            FileManager.default.contents(atPath: $0)
        },
        processMatchesRecord: @escaping @Sendable (ClaudeBackgroundSessionRegistration) -> Bool = {
            ClaudeBackgroundSessionRegistry.recordMatchesLiveProcess($0)
        }
    ) {
        self.sessionsDirectory = (configDirectory as NSString).appendingPathComponent("sessions")
        self.contentsOfDirectory = contentsOfDirectory
        self.readFile = readFile
        self.processMatchesRecord = processMatchesRecord
    }

    /// Claude's config directory for an environment: `CLAUDE_CONFIG_DIR`, else `~/.claude`.
    public static func configDirectory(
        environment: [String: String]?,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        if let configured = environment?["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            if configured == "~" { return homeDirectory }
            if configured.hasPrefix("~/") {
                return (homeDirectory as NSString).appendingPathComponent(String(configured.dropFirst(2)))
            }
            return configured
        }
        return (homeDirectory as NSString).appendingPathComponent(".claude")
    }

    /// Whether the record's PID is still the process that wrote it.
    ///
    /// PIDs are reused, so a recorded start time must match the live process.
    /// A record without one is accepted only when the process is Claude.
    public static func recordMatchesLiveProcess(_ record: ClaudeBackgroundSessionRegistration) -> Bool {
        if let domain = record.pidDomain, domain.lowercased() != "darwin" { return false }
        guard let started = processStartSeconds(record.processID) else { return false }
        if let recorded = record.processStart.flatMap(parseProcStart) {
            return abs(recorded - started) <= 1
        }
        return processLooksLikeClaude(record.processID)
    }

    /// The process start time in whole seconds since 1970, or `nil` when no such process exists.
    public static func processStartSeconds(_ processID: Int) -> Int? {
        guard processID > 0, processID <= Int(Int32.max) else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(processID)]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              info.kp_proc.p_pid == pid_t(processID) else {
            return nil
        }
        return Int(info.kp_proc.p_un.__p_starttime.tv_sec)
    }

    /// Reads and writes `procStart` with single spaces (`Sat Oct 3 18:52:39 2026`).
    /// DateFormatter is thread-safe for formatting and parsing on macOS 10.9+;
    /// the box keeps this building on SDKs that do not mark it Sendable.
    private struct ProcStartFormatterBox: @unchecked Sendable {
        let formatter: DateFormatter
    }

    private static let procStartFormatterBox: ProcStartFormatterBox = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return ProcStartFormatterBox(formatter: formatter)
    }()

    private static var procStartFormatter: DateFormatter { procStartFormatterBox.formatter }

    /// Parses Claude's `procStart` (`Sat Oct  3 18:52:39 2026`, UTC).
    public static func parseProcStart(_ value: String) -> Int? {
        let collapsed = value.split(separator: " ").joined(separator: " ")
        return procStartFormatter.date(from: collapsed).map { Int($0.timeIntervalSince1970) }
    }

    /// Renders a start time the way Claude records `procStart` (ctime layout,
    /// UTC): a one-digit day is padded with a second space.
    public static func formatProcStart(_ seconds: Int) -> String {
        var words = procStartFormatter
            .string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
            .split(separator: " ")
            .map(String.init)
        if words.count == 5, words[2].count == 1 { words[2] = " " + words[2] }
        return words.joined(separator: " ")
    }

    private static func processLooksLikeClaude(_ processID: Int) -> Bool {
        guard processID > 0, processID <= Int(Int32.max) else { return false }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(processID)]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return false
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &bytes, &size, nil, 0) == 0 else { return false }
        var index = MemoryLayout<Int32>.size
        func nextString() -> String? {
            while index < size, bytes[index] == 0 { index += 1 }
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            guard index > start else { return nil }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
        let executablePath = nextString() ?? ""
        let argv0 = nextString() ?? ""
        return URL(fileURLWithPath: argv0).lastPathComponent == "claude"
            || URL(fileURLWithPath: executablePath).lastPathComponent == "claude"
            || executablePath.contains("/claude/versions/")
    }

    /// Every background session in the registry whose owner process is still live.
    public func liveBackgroundSessions() -> [ClaudeBackgroundSessionRegistration] {
        guard let fileNames = contentsOfDirectory(sessionsDirectory) else { return [] }
        return fileNames.sorted().compactMap { fileName in
            guard fileName.hasSuffix(".json") else { return nil }
            let path = (sessionsDirectory as NSString).appendingPathComponent(fileName)
            guard let registration = backgroundRegistration(atPath: path),
                  processMatchesRecord(registration) else { return nil }
            return registration
        }
    }

    /// Returns the live background session `reference` names, or `nil` when
    /// the daemon no longer hosts it or the reference is ambiguous.
    public func liveBackgroundSession(matching reference: String) -> ClaudeBackgroundSessionRegistration? {
        Self.registration(matching: reference, in: liveBackgroundSessions())
    }

    /// Resolves an attach reference (session id, job id, name, or id prefix).
    public static func registration(
        matching reference: String,
        in registrations: [ClaudeBackgroundSessionRegistration]
    ) -> ClaudeBackgroundSessionRegistration? {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return nil }
        var exact: [ClaudeBackgroundSessionRegistration] = []
        var prefixed: [ClaudeBackgroundSessionRegistration] = []
        for registration in registrations {
            if lowercasedEqual(registration.sessionID, reference) ||
                registration.jobID.map({ lowercasedEqual($0, reference) }) == true ||
                registration.name == reference {
                exact.append(registration)
            } else if reference.count >= 8,
                      registration.sessionID.lowercased().hasPrefix(reference.lowercased()) {
                prefixed.append(registration)
            }
        }
        let candidates = exact.isEmpty ? prefixed : exact
        guard let first = candidates.first,
              candidates.allSatisfy({ lowercasedEqual($0.sessionID, first.sessionID) }) else {
            return nil
        }
        return first
    }

    private func backgroundRegistration(atPath path: String) -> ClaudeBackgroundSessionRegistration? {
        guard let data = readFile(path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = (object["kind"] as? String)?.lowercased(),
              kind == "bg" || kind == "background",
              let processID = (object["pid"] as? NSNumber)?.intValue,
              processID > 0,
              let sessionID = Self.identifier(object["sessionId"] as? String) else {
            return nil
        }
        return ClaudeBackgroundSessionRegistration(
            processID: processID,
            sessionID: sessionID,
            jobID: Self.identifier(object["jobId"] as? String),
            name: Self.normalized(object["name"] as? String)
                .flatMap { ClaudeBackgroundSessionAttach.containsControlCharacter($0) ? nil : $0 },
            processStart: Self.normalized(object["procStart"] as? String),
            pidDomain: Self.normalized(object["pidDomain"] as? String)
        )
    }

    /// Session and job ids are typed into a shell; accept only id characters.
    private static func identifier(_ value: String?) -> String? {
        guard let value = normalized(value),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII &&
                      (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
              }) else {
            return nil
        }
        return value
    }

    private static func lowercasedEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.lowercased() == rhs.lowercased()
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

/// The attach-only command that restores a background-session viewer.
public struct ClaudeBackgroundAttachPlan: Equatable, Sendable {
    /// The `claude attach <target>` argv, including any launcher prefix.
    public let arguments: [String]
    /// Environment assignments for the attach (config dir, routing, cmux preserve keys).
    public let environment: [String: String]
    public let registration: ClaudeBackgroundSessionRegistration
}

/// Decides whether a restored terminal should reattach a Claude background session.
public struct ClaudeBackgroundSessionAttach: Sendable {
    /// A Claude session cmux learned from its hooks for the restored terminal.
    public struct HookSession: Sendable {
        public var sessionID: String
        public var launchArguments: [String]
        public var launcher: String?
        public var environment: [String: String]

        public init(
            sessionID: String,
            launchArguments: [String],
            launcher: String?,
            environment: [String: String]
        ) {
            self.sessionID = sessionID
            self.launchArguments = launchArguments
            self.launcher = launcher
            self.environment = environment
        }
    }

    public typealias RegistryLookup = @Sendable (
        _ configDirectory: String,
        _ reference: String
    ) -> ClaudeBackgroundSessionRegistration?

    /// Keys an attach needs to reach the same daemon as the original session.
    /// Credentials are deliberately absent: attaching talks to the local
    /// daemon, not the API.
    static let attachEnvironmentKeys: Set<String> = [
        "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CONFIG_DIR",
    ]
    static let preservedEnvironmentKeyPrefix = "CMUX_PRESERVE_"
    private static let viewerLaunchers: Set<String> = ["env", "/usr/bin/env"]

    private let lookup: RegistryLookup
    private let homeDirectory: String

    public init(
        homeDirectory: String = NSHomeDirectory(),
        lookup: @escaping RegistryLookup = {
            ClaudeBackgroundSessionRegistry(configDirectory: $0).liveBackgroundSession(matching: $1)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.lookup = lookup
    }

    /// A registry lookup that scans each config directory at most once, for
    /// one restore pass over many panes.
    public static func memoizedRegistryLookup(
        scan: @escaping @Sendable (_ configDirectory: String) -> [ClaudeBackgroundSessionRegistration] = {
            ClaudeBackgroundSessionRegistry(configDirectory: $0).liveBackgroundSessions()
        }
    ) -> RegistryLookup {
        let memo = RegistryScanMemo()
        return { configDirectory, reference in
            ClaudeBackgroundSessionRegistry.registration(
                matching: reference,
                in: memo.registrations(for: configDirectory, scan: scan)
            )
        }
    }

    /// Recognizes a `claude attach <id|name>` viewer from a pane's foreground process.
    public static func viewer(
        arguments: [String],
        environment: [String: String]
    ) -> ClaudeBackgroundSessionViewer? {
        guard let executableIndex = arguments.firstIndex(where: isClaudeExecutable) else { return nil }
        let tail = arguments[(executableIndex + 1)...]
        guard tail.first == "attach" else { return nil }
        let words = Array(tail.dropFirst())
        let positionals = words.filter { !$0.hasPrefix("-") }
        // `claude attach` takes one target. A bare `--flag` may consume the
        // next word as its value, so prefer the one positional no option
        // precedes (`attach <id> --opt value`, `attach --opt value <id>`); a
        // lone positional after a boolean flag (`attach --flag <id>`) still counts.
        let unclaimed = words.indices.filter { index in
            !words[index].hasPrefix("-") &&
                !(index > 0 && words[index - 1].hasPrefix("-") && !words[index - 1].contains("="))
        }.map { words[$0] }
        let target = unclaimed.count == 1
            ? unclaimed.first
            : (unclaimed.isEmpty && positionals.count == 1 ? positionals.first : nil)
        guard let reference = target?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty,
              !containsControlCharacter(reference) else {
            return nil
        }
        let attachEnvironment = attachEnvironment(environment)
        return ClaudeBackgroundSessionViewer(
            reference: reference,
            launchArguments: sanitizedViewerLaunchArguments(Array(arguments[...executableIndex])),
            environment: attachEnvironment.isEmpty ? nil : attachEnvironment
        )
    }

    /// A viewer's launch prefix reduced to a `claude` executable (an absolute
    /// path or plain `claude`), optionally preceded by `env`. Anything else is
    /// dropped so a recorded prefix can never run another program.
    public static func sanitizedViewerLaunchArguments(_ arguments: [String]) -> [String] {
        guard let executable = arguments.last,
              isClaudeExecutable(executable),
              executable == "claude" || executable.hasPrefix("/"),
              !containsControlCharacter(executable) else {
            return ["claude"]
        }
        let prefix = arguments.dropLast()
        if prefix.count == 1, let launcher = prefix.first, viewerLaunchers.contains(launcher) {
            return [launcher, executable]
        }
        return [executable]
    }

    /// The attach-relevant subset of a captured environment.
    public static func attachEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, value in
            !value.isEmpty &&
                !containsControlCharacter(value) &&
                (attachEnvironmentKeys.contains(key) || key.hasPrefix(preservedEnvironmentKeyPrefix))
        }
    }

    /// `claude attach <target>` with the restore launcher-prefix rule: keep any
    /// outer wrapper words and the recorded `claude` executable, else use the
    /// recorded `sr claude` launcher, else plain `claude`.
    public static func attachArguments(
        target: String,
        launchArguments: [String],
        launcher: String?
    ) -> [String] {
        let prefix: [String]
        if let executableIndex = launchArguments.firstIndex(where: isClaudeExecutable) {
            prefix = Array(launchArguments[...executableIndex])
        } else if launcher?.lowercased() == "sr" {
            prefix = ["sr", "claude"]
        } else {
            prefix = ["claude"]
        }
        return prefix + ["attach", target]
    }

    /// Plans an attach when Claude's daemon still hosts the session the pane
    /// was viewing (`viewer`) or the session its hooks reported (`hookSession`).
    ///
    /// Returns `nil` for interactive sessions and for background sessions the
    /// daemon no longer hosts, so callers keep their existing restore.
    public func plan(
        viewer: ClaudeBackgroundSessionViewer?,
        hookSession: HookSession?
    ) -> ClaudeBackgroundAttachPlan? {
        if let viewer,
           let plan = viewerPlan(viewer, hookSession: hookSession) {
            return plan
        }
        guard let hookSession,
              !hookSession.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let configDirectory = ClaudeBackgroundSessionRegistry.configDirectory(
            environment: hookSession.environment,
            homeDirectory: homeDirectory
        )
        guard let registration = lookup(configDirectory, hookSession.sessionID) else { return nil }
        return ClaudeBackgroundAttachPlan(
            arguments: Self.attachArguments(
                target: registration.attachTarget,
                launchArguments: hookSession.launchArguments,
                launcher: hookSession.launcher
            ),
            environment: Self.attachEnvironment(hookSession.environment),
            registration: registration
        )
    }

    private func viewerPlan(
        _ viewer: ClaudeBackgroundSessionViewer,
        hookSession: HookSession?
    ) -> ClaudeBackgroundAttachPlan? {
        let viewerEnvironment = Self.attachEnvironment(viewer.environment ?? [:])
        let configDirectory = ClaudeBackgroundSessionRegistry.configDirectory(
            environment: viewerEnvironment,
            homeDirectory: homeDirectory
        )
        guard let registration = lookup(configDirectory, viewer.reference) else { return nil }
        var environment = viewerEnvironment
        if let hookSession,
           hookSession.sessionID.lowercased() == registration.sessionID.lowercased() {
            // The hook binding captured the session's own launch environment.
            environment.merge(Self.attachEnvironment(hookSession.environment)) { _, hook in hook }
        }
        return ClaudeBackgroundAttachPlan(
            arguments: Self.sanitizedViewerLaunchArguments(viewer.launchArguments)
                + ["attach", registration.attachTarget],
            environment: environment,
            registration: registration
        )
    }

    static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) }
    }

    private static func isClaudeExecutable(_ argument: String) -> Bool {
        URL(fileURLWithPath: argument).lastPathComponent == "claude"
    }
}

/// One restore pass's registry scans, keyed by config directory.
private final class RegistryScanMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var scans: [String: [ClaudeBackgroundSessionRegistration]] = [:]

    func registrations(
        for configDirectory: String,
        scan: (String) -> [ClaudeBackgroundSessionRegistration]
    ) -> [ClaudeBackgroundSessionRegistration] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = scans[configDirectory] { return cached }
        let scanned = scan(configDirectory)
        scans[configDirectory] = scanned
        return scanned
    }
}
