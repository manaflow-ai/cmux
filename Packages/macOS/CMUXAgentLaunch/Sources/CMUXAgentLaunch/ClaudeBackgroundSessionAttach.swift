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
    /// The viewer's argv up to and including the `claude` executable.
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

    public init(processID: Int, sessionID: String, jobID: String?, name: String?) {
        self.processID = processID
        self.sessionID = sessionID
        self.jobID = jobID
        self.name = name
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
    private let isProcessAlive: @Sendable (Int) -> Bool

    public init(
        configDirectory: String,
        contentsOfDirectory: @escaping @Sendable (String) -> [String]? = {
            try? FileManager.default.contentsOfDirectory(atPath: $0)
        },
        readFile: @escaping @Sendable (String) -> Data? = {
            FileManager.default.contents(atPath: $0)
        },
        isProcessAlive: @escaping @Sendable (Int) -> Bool = { ClaudeBackgroundSessionRegistry.processIsAlive($0) }
    ) {
        self.sessionsDirectory = (configDirectory as NSString).appendingPathComponent("sessions")
        self.contentsOfDirectory = contentsOfDirectory
        self.readFile = readFile
        self.isProcessAlive = isProcessAlive
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

    public static func processIsAlive(_ processID: Int) -> Bool {
        guard processID > 0, processID <= Int(Int32.max) else { return false }
        if kill(pid_t(processID), 0) == 0 { return true }
        return errno == EPERM
    }

    /// Returns the live background session `reference` names, or `nil` when
    /// the daemon no longer hosts it or the reference is ambiguous.
    public func liveBackgroundSession(matching reference: String) -> ClaudeBackgroundSessionRegistration? {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty,
              let fileNames = contentsOfDirectory(sessionsDirectory) else {
            return nil
        }
        var exact: [ClaudeBackgroundSessionRegistration] = []
        var prefixed: [ClaudeBackgroundSessionRegistration] = []
        for fileName in fileNames where fileName.hasSuffix(".json") {
            let path = (sessionsDirectory as NSString).appendingPathComponent(fileName)
            guard let registration = backgroundRegistration(atPath: path) else { continue }
            if Self.lowercasedEqual(registration.sessionID, reference) ||
                registration.jobID.map({ Self.lowercasedEqual($0, reference) }) == true ||
                registration.name == reference {
                exact.append(registration)
            } else if reference.count >= 8,
                      registration.sessionID.lowercased().hasPrefix(reference.lowercased()) {
                prefixed.append(registration)
            }
        }
        let candidates = exact.isEmpty ? prefixed : exact
        guard let first = candidates.first,
              candidates.allSatisfy({ Self.lowercasedEqual($0.sessionID, first.sessionID) }),
              isProcessAlive(first.processID) else {
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
              let sessionID = Self.normalized(object["sessionId"] as? String) else {
            return nil
        }
        return ClaudeBackgroundSessionRegistration(
            processID: processID,
            sessionID: sessionID,
            jobID: Self.normalized(object["jobId"] as? String),
            name: Self.normalized(object["name"] as? String)
        )
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

    /// Keys an attach needs to reach the same daemon as the original session.
    /// Credentials are deliberately absent: the typed command lands in shell
    /// history, and attaching talks to the local daemon, not the API.
    static let attachEnvironmentKeys: Set<String> = [
        "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CONFIG_DIR",
    ]
    static let preservedEnvironmentKeyPrefix = "CMUX_PRESERVE_"

    private let lookup: @Sendable (_ configDirectory: String, _ reference: String) -> ClaudeBackgroundSessionRegistration?
    private let homeDirectory: String

    public init(
        homeDirectory: String = NSHomeDirectory(),
        lookup: @escaping @Sendable (_ configDirectory: String, _ reference: String) -> ClaudeBackgroundSessionRegistration? = {
            ClaudeBackgroundSessionRegistry(configDirectory: $0).liveBackgroundSession(matching: $1)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.lookup = lookup
    }

    /// Recognizes a `claude attach <id|name>` viewer from a pane's foreground process.
    public static func viewer(
        arguments: [String],
        environment: [String: String]
    ) -> ClaudeBackgroundSessionViewer? {
        guard let executableIndex = arguments.firstIndex(where: isClaudeExecutable) else { return nil }
        let tail = arguments[(executableIndex + 1)...]
        guard tail.first == "attach",
              let reference = tail.dropFirst().first(where: { !$0.hasPrefix("-") })?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty else {
            return nil
        }
        let attachEnvironment = attachEnvironment(environment)
        return ClaudeBackgroundSessionViewer(
            reference: reference,
            launchArguments: Array(arguments[...executableIndex]),
            environment: attachEnvironment.isEmpty ? nil : attachEnvironment
        )
    }

    /// The attach-relevant subset of a captured environment.
    public static func attachEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, value in
            !value.isEmpty &&
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
        let viewerEnvironment = viewer.environment ?? [:]
        let configDirectory = ClaudeBackgroundSessionRegistry.configDirectory(
            environment: viewerEnvironment,
            homeDirectory: homeDirectory
        )
        guard let registration = lookup(configDirectory, viewer.reference) else { return nil }
        var environment = Self.attachEnvironment(viewerEnvironment)
        if let hookSession,
           hookSession.sessionID.lowercased() == registration.sessionID.lowercased() {
            // The hook binding captured the session's own launch environment.
            environment.merge(Self.attachEnvironment(hookSession.environment)) { _, hook in hook }
        }
        return ClaudeBackgroundAttachPlan(
            arguments: Self.attachArguments(
                target: registration.attachTarget,
                launchArguments: viewer.launchArguments,
                launcher: nil
            ),
            environment: environment,
            registration: registration
        )
    }

    private static func isClaudeExecutable(_ argument: String) -> Bool {
        URL(fileURLWithPath: argument).lastPathComponent == "claude"
    }
}
