import CoreGraphics
import Foundation
import Bonsplit

enum SessionSnapshotSchema {
    static let currentVersion = 1
}

enum SessionPersistencePolicy {
    static let defaultSidebarWidth: Double = 200
    static let minimumSidebarWidth: Double = 180
    static let maximumSidebarWidth: Double = 600
    static let minimumWindowWidth: Double = 300
    static let minimumWindowHeight: Double = 200
    static let autosaveInterval: TimeInterval = 8.0
    static let maxWindowsPerSnapshot: Int = 12
    static let maxWorkspacesPerWindow: Int = 128
    static let maxPanelsPerWorkspace: Int = 512
    static let maxScrollbackLinesPerTerminal: Int = 4000
    static let maxScrollbackCharactersPerTerminal: Int = 400_000

    static func sanitizedSidebarWidth(_ candidate: Double?) -> Double {
        let fallback = defaultSidebarWidth
        guard let candidate, candidate.isFinite else { return fallback }
        return min(max(candidate, minimumSidebarWidth), maximumSidebarWidth)
    }

    static func truncatedScrollback(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if text.count <= maxScrollbackCharactersPerTerminal {
            return text
        }
        let initialStart = text.index(text.endIndex, offsetBy: -maxScrollbackCharactersPerTerminal)
        let safeStart = ansiSafeTruncationStart(in: text, initialStart: initialStart)
        return String(text[safeStart...])
    }

    /// If truncation starts in the middle of an ANSI CSI escape sequence, advance
    /// to the first printable character after that sequence to avoid replaying
    /// malformed control bytes.
    private static func ansiSafeTruncationStart(in text: String, initialStart: String.Index) -> String.Index {
        guard initialStart > text.startIndex else { return initialStart }
        let escape = "\u{001B}"

        guard let lastEscape = text[..<initialStart].lastIndex(of: Character(escape)) else {
            return initialStart
        }
        let csiMarker = text.index(after: lastEscape)
        guard csiMarker < text.endIndex, text[csiMarker] == "[" else {
            return initialStart
        }

        // If a final CSI byte exists before the truncation boundary, we are not
        // inside a partial sequence.
        if csiFinalByteIndex(in: text, from: csiMarker, upperBound: initialStart) != nil {
            return initialStart
        }

        // We are inside a CSI sequence. Skip to the first character after the
        // sequence terminator if it exists.
        guard let final = csiFinalByteIndex(in: text, from: csiMarker, upperBound: text.endIndex) else {
            return initialStart
        }
        let next = text.index(after: final)
        return next < text.endIndex ? next : text.endIndex
    }

    private static func csiFinalByteIndex(
        in text: String,
        from csiMarker: String.Index,
        upperBound: String.Index
    ) -> String.Index? {
        var index = text.index(after: csiMarker)
        while index < upperBound {
            guard let scalar = text[index].unicodeScalars.first?.value else {
                index = text.index(after: index)
                continue
            }
            if scalar >= 0x40, scalar <= 0x7E {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }
}

enum SessionRestorePolicy {
    static func isRunningUnderAutomatedTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["CMUX_UI_TEST_MODE"] == "1" {
            return true
        }
        if environment.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) {
            return true
        }
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if environment["XCTestBundlePath"] != nil {
            return true
        }
        if environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        if environment["XCInjectBundle"] != nil {
            return true
        }
        if environment["XCInjectBundleInto"] != nil {
            return true
        }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true {
            return true
        }
        return false
    }

    static func shouldAttemptRestore(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["CMUX_DISABLE_SESSION_RESTORE"] == "1" {
            return false
        }
        if isRunningUnderAutomatedTests(environment: environment) {
            return false
        }

        let extraArgs = arguments
            .dropFirst()
            .filter { !$0.hasPrefix("-psn_") }

        // Any explicit launch argument is treated as an explicit open intent.
        return extraArgs.isEmpty
    }
}

struct SessionRectSnapshot: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct SessionDisplaySnapshot: Codable, Sendable {
    var displayID: UInt32?
    var frame: SessionRectSnapshot?
    var visibleFrame: SessionRectSnapshot?
}

enum SessionSidebarSelection: String, Codable, Sendable, Equatable {
    case tabs
    case notifications

    init(selection: SidebarSelection) {
        switch selection {
        case .tabs:
            self = .tabs
        case .notifications:
            self = .notifications
        }
    }

    var sidebarSelection: SidebarSelection {
        switch self {
        case .tabs:
            return .tabs
        case .notifications:
            return .notifications
        }
    }
}

struct SessionSidebarSnapshot: Codable, Sendable {
    var isVisible: Bool
    var selection: SessionSidebarSelection
    var width: Double?
}

struct SessionStatusEntrySnapshot: Codable, Sendable {
    var key: String
    var value: String
    var icon: String?
    var color: String?
    var timestamp: TimeInterval
}

struct SessionLogEntrySnapshot: Codable, Sendable {
    var message: String
    var level: String
    var source: String?
    var timestamp: TimeInterval
}

struct SessionProgressSnapshot: Codable, Sendable {
    var value: Double
    var label: String?
}

struct SessionGitBranchSnapshot: Codable, Sendable {
    var branch: String
    var isDirty: Bool
}

struct SessionTerminalPanelSnapshot: Codable, Sendable {
    var workingDirectory: String?
    var scrollback: String?
    var restoreCommand: String?
    /// The command that was running when the session was saved (detected from process tree)
    var detectedCommand: String?
    /// Whether this terminal was remote-backed (SSH) when saved.
    /// Used to restore local terminals correctly in a remote-configured workspace.
    var isRemoteBacked: Bool?
}

struct SessionBrowserPanelSnapshot: Codable, Sendable {
    var urlString: String?
    var profileID: UUID?
    var shouldRenderWebView: Bool
    var pageZoom: Double
    var developerToolsVisible: Bool
    var backHistoryURLStrings: [String]?
    var forwardHistoryURLStrings: [String]?
}

struct SessionMarkdownPanelSnapshot: Codable, Sendable {
    var filePath: String
}

struct SessionPanelSnapshot: Codable, Sendable {
    var id: UUID
    var type: PanelType
    var title: String?
    var customTitle: String?
    var directory: String?
    var isPinned: Bool
    var isManuallyUnread: Bool
    var gitBranch: SessionGitBranchSnapshot?
    var listeningPorts: [Int]
    var ttyName: String?
    var terminal: SessionTerminalPanelSnapshot?
    var browser: SessionBrowserPanelSnapshot?
    var markdown: SessionMarkdownPanelSnapshot?
}

enum SessionSplitOrientation: String, Codable, Sendable {
    case horizontal
    case vertical

    init(_ orientation: SplitOrientation) {
        switch orientation {
        case .horizontal:
            self = .horizontal
        case .vertical:
            self = .vertical
        }
    }

    var splitOrientation: SplitOrientation {
        switch self {
        case .horizontal:
            return .horizontal
        case .vertical:
            return .vertical
        }
    }
}

struct SessionPaneLayoutSnapshot: Codable, Sendable {
    var panelIds: [UUID]
    var selectedPanelId: UUID?
}

struct SessionSplitLayoutSnapshot: Codable, Sendable {
    var orientation: SessionSplitOrientation
    var dividerPosition: Double
    var first: SessionWorkspaceLayoutSnapshot
    var second: SessionWorkspaceLayoutSnapshot
}

indirect enum SessionWorkspaceLayoutSnapshot: Codable, Sendable {
    case pane(SessionPaneLayoutSnapshot)
    case split(SessionSplitLayoutSnapshot)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            self = .pane(try container.decode(SessionPaneLayoutSnapshot.self, forKey: .pane))
        case "split":
            self = .split(try container.decode(SessionSplitLayoutSnapshot.self, forKey: .split))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported layout node type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try container.encode("pane", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try container.encode("split", forKey: .type)
            try container.encode(split, forKey: .split)
        }
    }
}

struct SessionWorkspaceSnapshot: Codable, Sendable {
    var processTitle: String
    var customTitle: String?
    var customDescription: String?
    var customColor: String?
    var isPinned: Bool
    var currentDirectory: String
    var focusedPanelId: UUID?
    var layout: SessionWorkspaceLayoutSnapshot
    var panels: [SessionPanelSnapshot]
    var statusEntries: [SessionStatusEntrySnapshot]
    var logEntries: [SessionLogEntrySnapshot]
    var progress: SessionProgressSnapshot?
    var gitBranch: SessionGitBranchSnapshot?
}

struct SessionTabManagerSnapshot: Codable, Sendable {
    var selectedWorkspaceIndex: Int?
    var workspaces: [SessionWorkspaceSnapshot]
}

struct SessionWindowSnapshot: Codable, Sendable {
    var frame: SessionRectSnapshot?
    var display: SessionDisplaySnapshot?
    var tabManager: SessionTabManagerSnapshot
    var sidebar: SessionSidebarSnapshot
}

struct AppSessionSnapshot: Codable, Sendable {
    var version: Int
    var createdAt: TimeInterval
    var windows: [SessionWindowSnapshot]
}

enum SessionPersistenceStore {
    static func load(fileURL: URL? = nil) -> AppSessionSnapshot? {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        guard let snapshot = try? decoder.decode(AppSessionSnapshot.self, from: data) else { return nil }
        guard snapshot.version == SessionSnapshotSchema.currentVersion else { return nil }
        guard !snapshot.windows.isEmpty else { return nil }
        return snapshot
    }

    @discardableResult
    static func save(_ snapshot: AppSessionSnapshot, fileURL: URL? = nil) -> Bool {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return false }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let data = try encodedSnapshotData(snapshot)
            if let existingData = try? Data(contentsOf: fileURL), existingData == data {
                return true
            }
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func encodedSnapshotData(_ snapshot: AppSessionSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func removeSnapshot(fileURL: URL? = nil) {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func defaultSnapshotFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil
    ) -> URL? {
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.cmuxterm.app"
        let safeBundleId = bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return resolvedAppSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("session-\(safeBundleId).json", isDirectory: false)
    }
}

enum SessionScrollbackReplayStore {
    static let environmentKey = "CMUX_RESTORE_SCROLLBACK_FILE"
    private static let directoryName = "cmux-session-scrollback"
    private static let ansiEscape = "\u{001B}"
    private static let ansiReset = "\u{001B}[0m"

    static func replayEnvironment(
        for scrollback: String?,
        tempDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [String: String] {
        guard let replayText = normalizedScrollback(scrollback) else { return [:] }
        guard let replayFileURL = writeReplayFile(
            contents: replayText,
            tempDirectory: tempDirectory
        ) else {
            return [:]
        }
        return [environmentKey: replayFileURL.path]
    }

    private static func normalizedScrollback(_ scrollback: String?) -> String? {
        guard let scrollback else { return nil }
        guard scrollback.contains(where: { !$0.isWhitespace }) else { return nil }
        guard let truncated = SessionPersistencePolicy.truncatedScrollback(scrollback) else { return nil }
        return ansiSafeReplayText(truncated)
    }

    /// Preserve ANSI color state safely across replay boundaries.
    private static func ansiSafeReplayText(_ text: String) -> String {
        guard text.contains(ansiEscape) else { return text }
        var output = text
        if !output.hasPrefix(ansiReset) {
            output = ansiReset + output
        }
        if !output.hasSuffix(ansiReset) {
            output += ansiReset
        }
        return output
    }

    private static func writeReplayFile(contents: String, tempDirectory: URL) -> URL? {
        guard let data = contents.data(using: .utf8) else { return nil }
        let directory = tempDirectory.appendingPathComponent(directoryName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let fileURL = directory
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
                .appendingPathExtension("txt")
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }
}

// MARK: - Session Restore Command Settings

enum SessionRestoreCommandSettings {
    static let enabledKey = "sessionRestoreCommandsEnabled"
    static let allowlistKey = "sessionRestoreCommandAllowlist"
    static let defaultEnabled = true

    /// Default allowlist of commands safe to auto-restore.
    /// Use `*` suffix for prefix matching (command + any arguments).
    static let defaultAllowlistPatterns = [
        // Coding agents
        "opencode *",
        "claude *",
        "codex *",
        "aider *",
        // Dev servers
        "npm run dev *",
        "npm start *",
        "yarn dev *",
        "pnpm dev *",
        "bun dev *",
        "bun run dev *",
        // Rust
        "cargo run *",
        // Python
        "uvicorn *",
        "flask run *",
        // Watchers/logs
        "tail -f *",
    ]

    static let defaultAllowlistText = defaultAllowlistPatterns.joined(separator: "\n")

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }

    static func normalizedAllowlistPatterns(defaults: UserDefaults = .standard) -> [String] {
        normalizedAllowlistPatterns(rawValue: defaults.string(forKey: allowlistKey))
    }

    static func normalizedAllowlistPatterns(rawValue: String?) -> [String] {
        // If user provided an explicit value (even if empty/whitespace-only), respect it.
        // Only fall back to defaults when rawValue is nil (not set at all).
        guard let rawValue else {
            return defaultAllowlistPatterns
        }
        let parsed = parsePatterns(from: rawValue)
        // If user explicitly cleared the allowlist, return empty (disables all restores)
        return parsed
    }

    private static func parsePatterns(from text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    // MARK: - Hardcoded Denylist (Safety Net)

    // MARK: - Denylist Configuration
    //
    // Defense-in-depth: These lists block dangerous commands from being auto-restored.
    // The primary security boundary is the user's allowlist, but these patterns catch
    // catastrophic mistakes even if the allowlist is too permissive.
    //
    // Philosophy: Start aggressive, loosen as needed. False positives are safer than
    // allowing destructive commands to auto-restore.

    /// Dangerous executables blocked anywhere in a command (word-boundary aware).
    /// Matches: "sudo rm", "cd /tmp && sudo", "/usr/bin/sudo", "$(curl ...)", etc.
    /// Does NOT match: "sudoku", "rm-old-files" (no word boundary).
    /// Uses Set for O(1) lookup.
    private static let dangerousExecutables: Set<String> = [
        // Privilege escalation
        "sudo", "doas", "su", "pkexec", "runas",
        // Destructive file operations
        "rm", "rmdir", "shred", "srm", "unlink", "mv",
        // Disk/partition operations
        "dd", "mkfs", "newfs", "fdisk", "parted", "diskutil", "hdparm", "badblocks",
        // System control
        "reboot", "shutdown", "halt", "poweroff", "init",
        // Permission/ownership changes
        "chmod", "chown", "chgrp", "chattr", "setfacl",
        // Process control
        "kill", "killall", "pkill", "xkill",
        // Remote code execution vectors
        "curl", "wget",
        // Filesystem check (can destroy encrypted volumes)
        "fsck",
        // Database admin
        "dropdb", "dropuser", "createdb", "createuser",
        // Cron/scheduler
        "crontab",
        // macOS system integrity
        "csrutil", "nvram", "bless",
        // Network/firewall
        "iptables", "pfctl", "networksetup",
        // Dangerous archivers (can overwrite system files as root)
        "tar",
        // Kernel module manipulation
        "modprobe", "insmod", "rmmod", "modinfo",
        // User/group manipulation
        "useradd", "userdel", "usermod", "groupadd", "groupdel", "groupmod",
        "chpasswd", "passwd",
        // Additional archiver with dangerous options
        "rsync",
        // Command execution helpers
        "xargs", "find",
        // Netcat - reverse shell vector
        "nc", "ncat", "netcat",
        // Package managers (install-only, no run/script capability)
        // These modify system state and have no legitimate auto-restore use case.
        // Note: npm/yarn/pnpm/bun are NOT here because they have `run`/`dev` scripts.
        "apt", "apt-get", "dpkg", "aptitude",
        "yum", "dnf", "rpm",
        "brew", "port",
        "pacman", "yay", "paru", "makepkg",
        "zypper",
        "apk",
        "snap", "flatpak",
        "pip", "pip3", "pipx",
        "gem",
        "cpan", "cpanm",
        // go install is dangerous (downloads and installs binaries), go run is in allowlist
        // Note: "go" itself is not blocked because "go run" is legitimate
    ]

    /// Substrings that block a command if found anywhere.
    /// Used for: credentials, destructive operations, sensitive file access.
    private static let denylistContains = [
        // API keys and tokens
        "--api-key=", "--api-key ",
        "--apikey=", "--apikey ",
        "--token=", "--token ",
        "--access-token=", "--access-token ",
        "--auth-token=", "--auth-token ",
        "--bearer=", "--bearer ",
        "--secret=", "--secret ",
        "--client-secret=", "--client-secret ",
        // Passwords (long flags only; MySQL -p handled separately)
        "--password=", "--password ",
        "--passwd=", "--passwd ",
        // AWS credentials
        "--aws-access-key-id=", "--aws-secret-access-key=",
        "AWS_ACCESS_KEY_ID=", "AWS_SECRET_ACCESS_KEY=",
        // SSH/auth keys
        "--private-key=", "--private-key ",
        "--ssh-key=", "--ssh-key ",
        // Generic auth
        "--credentials=", "--credentials ",
        "--auth=", "--auth ",
        // Database connection strings
        "mongodb://", "mongodb+srv://",
        "postgresql://", "postgres://",
        "mysql://", "redis://", "amqp://", "rediss://",
        // Git destructive
        "git push --force", "git push -f",
        "git reset --hard",
        "git clean -f",
        "git checkout --force",
        // Database destructive
        "drop database", "drop table", "drop schema", "drop index",
        "truncate table", "truncate ",
        "delete from",
        // System services
        "systemctl stop", "systemctl disable", "systemctl mask",
        "launchctl unload", "launchctl bootout", "launchctl remove",
        "service stop",
        // Container destructive
        "docker system prune",
        "docker rm -f", "docker container rm -f",
        "docker volume rm", "docker volume prune",
        "docker image prune", "docker container prune",
        "podman system prune", "podman rm -f",
        // Kubernetes destructive
        "kubectl delete namespace", "kubectl delete ns",
        "kubectl delete --all",
        "kubectl drain", "kubectl cordon",
        // Environment manipulation
        "unset PATH",
        "export PATH=",
        // Piped shell execution
        "| sh", "| bash", "| zsh", "| ksh", "| fish",
        "| /bin/sh", "| /bin/bash", "| /bin/zsh",
        // History replay
        "history | sh", "history | bash", "history | zsh",
        "fc -s",
        // Command injection via embedded newlines/carriage returns
        // Defense-in-depth: also blocked at initialInput validation layer
        "\n", "\r",
        // Fork bomb
        ":(){ :|:& };:",
        // Disk write targets
        "of=/dev/sd", "of=/dev/nvme", "of=/dev/disk",
        "> /dev/sd", "> /dev/nvme",
        // Sensitive file access
        "/etc/shadow",
        ".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/id_dsa",
        ".ssh/authorized_keys",
        ".aws/credentials",
        ".kube/config",
        ".npmrc",
        ".netrc",
        ".git-credentials",
        ".docker/config.json",
        // npm/yarn destructive
        "npm unpublish",
        "npm deprecate",
        // Homebrew destructive (macOS)
        "brew uninstall --force",
        "brew remove --force",
        "brew unlink --force",
        // SysRq magic key - instant reboot/crash
        "/proc/sysrq-trigger",
        "echo b > /proc/sysrq",
        "echo o > /proc/sysrq",
        "echo c > /proc/sysrq",
        // Shell exec redirect - silences shell
        "exec >",
        "exec 2>",
        "exec &>",
        // Additional disk device targets
        "of=/dev/hd", "of=/dev/vd", "of=/dev/xvd",
        "> /dev/hd", "> /dev/vd",

        // Additional fork bomb variants
        ".() { .|.& };.",
        "bomb() { bomb | bomb & }; bomb",
        // Infinite loops that fill disk
        "while true; do",
        "for (( ; ; )); do",
        "while :; do",
        // LD_PRELOAD injection
        "LD_PRELOAD=",
        "LD_LIBRARY_PATH=",
    ]

    /// Check if a command matches the allowlist.
    /// - Exact match: "opencode" matches only "opencode"
    /// - Prefix match: "opencode *" matches "opencode", "opencode --flag", etc.
    /// - Commands matching the hardcoded denylist are NEVER allowed.
    /// - Returns false immediately if sessionRestoreCommandsEnabled is disabled.
    static func isCommandAllowed(_ command: String, defaults: UserDefaults = .standard) -> Bool {
        guard isEnabled(defaults: defaults) else { return false }
        return isCommandAllowed(command, rawAllowlist: defaults.string(forKey: allowlistKey))
    }

    static func isCommandAllowed(_ command: String, rawAllowlist: String?) -> Bool {
        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCommand.isEmpty else { return false }

        // Safety net: hardcoded denylist always blocks, regardless of user allowlist
        if isCommandDenied(normalizedCommand) {
            return false
        }

        let patterns = normalizedAllowlistPatterns(rawValue: rawAllowlist)
        return patterns.contains { pattern in
            commandMatchesPattern(normalizedCommand, pattern: pattern)
        }
    }

    /// Normalize and validate a restore command in one step.
    /// Returns the trimmed command if allowed, nil otherwise.
    /// Use this helper to avoid duplicating trim + allowlist check logic.
    static func validatedRestoreCommand(_ command: String?) -> String? {
        guard let command, !command.isEmpty else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isCommandAllowed(trimmed) else { return nil }
        return trimmed
    }

    /// Check if command matches the hardcoded denylist (case-insensitive for safety)
    private static func isCommandDenied(_ command: String) -> Bool {
        let lowercased = command.lowercased()

        // Check if any dangerous executable appears anywhere in the command.
        // This catches: "sudo rm", "cd /tmp && sudo rm", "echo | rm -rf", "/usr/bin/sudo", etc.
        if containsDangerousExecutable(lowercased) {
            return true
        }

        // Check substring matches (credentials, destructive patterns, sensitive files)
        for substring in denylistContains {
            // Special handling for control characters: Swift treats CRLF (\r\n) as a single
            // grapheme cluster, so `str.contains("\r")` returns false for a CRLF string.
            // Check at the Unicode scalar level for single control characters.
            if substring.count == 1, let scalar = substring.unicodeScalars.first,
               scalar == "\r" || scalar == "\n" {
                if lowercased.unicodeScalars.contains(scalar) {
                    return true
                }
            } else if lowercased.contains(substring.lowercased()) {
                return true
            }
        }

        // Check MySQL-family commands with -p flag (password)
        // These tools use -p for password, unlike cargo/flask/npm which use it for port/package
        if isMySQLPasswordCommand(lowercased) {
            return true
        }

        return false
    }

    /// Check if a dangerous executable appears anywhere in the command.
    /// Looks for word boundaries: start of string, space, /, |, ;, &, `, $(
    /// This catches both direct invocations and shell-chained commands.
    private static func containsDangerousExecutable(_ lowercasedCommand: String) -> Bool {
        // Characters that can precede an executable name
        let boundaryChars: Set<Character> = [" ", "\t", "\n", "\r", "/", "|", ";", "&", "`", "("]
        // Characters that can follow an executable name (word boundary)
        let trailingBoundaryChars: Set<Character> = [" ", "\t", ";", "|", "&", ")", "\n", "\"", "'", "`", "$"]

        func hasValidTrailingBoundary(_ index: String.Index) -> Bool {
            index == lowercasedCommand.endIndex || trailingBoundaryChars.contains(lowercasedCommand[index])
        }

        for executable in dangerousExecutables {
            // Check if command starts with the executable (e.g., "rm -rf", "rm;", "rm|")
            if lowercasedCommand.hasPrefix(executable) {
                let afterIndex = lowercasedCommand.index(
                    lowercasedCommand.startIndex,
                    offsetBy: executable.count,
                    limitedBy: lowercasedCommand.endIndex
                ) ?? lowercasedCommand.endIndex
                if hasValidTrailingBoundary(afterIndex) {
                    return true
                }
            }

            // Check if executable appears after a boundary character
            // Scan ALL occurrences, not just the first (handles "echo sudoers && sudo rm")
            for boundary in boundaryChars {
                let pattern = String(boundary) + executable
                var searchStart = lowercasedCommand.startIndex
                while let range = lowercasedCommand.range(
                    of: pattern,
                    range: searchStart..<lowercasedCommand.endIndex
                ) {
                    // Verify it's followed by end of string or another boundary
                    let afterIndex = range.upperBound
                    if hasValidTrailingBoundary(afterIndex) {
                        return true
                    }
                    // Move past this match to find subsequent occurrences
                    searchStart = lowercasedCommand.index(after: range.lowerBound)
                }
            }
        }
        return false
    }

    /// Check if a command is a MySQL-family tool with -p password flag
    /// MySQL, MariaDB, mysqldump, mysqladmin all use -p for password
    private static func isMySQLPasswordCommand(_ lowercasedCommand: String) -> Bool {
        let mysqlTools: Set<String> = ["mysql", "mariadb", "mysqldump", "mysqladmin"]

        // Parse the leading shell token (handles quoted paths like '/My App/mysql')
        let toolName = parseLeadingExecutableBasename(lowercasedCommand)
        guard mysqlTools.contains(toolName) else { return false }

        // Check if -p flag is present (with or without space before value)
        // -p, -pPASSWORD, or -p PASSWORD
        return lowercasedCommand.contains(" -p") || lowercasedCommand.contains(" -p=")
    }

    /// Parse the leading executable token from a command line, handling shell quoting.
    /// Returns the basename of the executable (e.g., "mysql" from "'/My App/mysql' --flag")
    private static func parseLeadingExecutableBasename(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }

        var executablePath: String
        let firstChar = trimmed.first!

        if firstChar == "'" {
            // Single-quoted: find closing quote, handle escaped quotes
            if let closeIndex = findClosingSingleQuote(trimmed, startAfter: trimmed.startIndex) {
                let start = trimmed.index(after: trimmed.startIndex)
                executablePath = String(trimmed[start..<closeIndex])
                // Unescape '\'' sequences
                executablePath = executablePath.replacingOccurrences(of: "'\\''", with: "'")
            } else {
                // Unclosed quote, take whole thing minus opening quote
                executablePath = String(trimmed.dropFirst())
            }
        } else if firstChar == "\"" {
            // Double-quoted: find closing quote
            if let closeIndex = findClosingDoubleQuote(trimmed, startAfter: trimmed.startIndex) {
                let start = trimmed.index(after: trimmed.startIndex)
                executablePath = String(trimmed[start..<closeIndex])
                // Unescape basic sequences
                executablePath = executablePath.replacingOccurrences(of: "\\\"", with: "\"")
                executablePath = executablePath.replacingOccurrences(of: "\\\\", with: "\\")
            } else {
                executablePath = String(trimmed.dropFirst())
            }
        } else {
            // Unquoted: take until first whitespace
            if let spaceIndex = trimmed.firstIndex(where: { $0.isWhitespace }) {
                executablePath = String(trimmed[..<spaceIndex])
            } else {
                executablePath = trimmed
            }
        }

        // Extract basename
        return URL(fileURLWithPath: executablePath).lastPathComponent
    }

    /// Find closing single quote, handling '\'' escape sequences
    private static func findClosingSingleQuote(_ s: String, startAfter: String.Index) -> String.Index? {
        var i = s.index(after: startAfter)
        while i < s.endIndex {
            if s[i] == "'" {
                // Check if this is start of '\'' escape sequence
                let remaining = s[i...]
                if remaining.hasPrefix("'\\''") {
                    // Skip the escape sequence
                    i = s.index(i, offsetBy: 4, limitedBy: s.endIndex) ?? s.endIndex
                } else {
                    return i
                }
            } else {
                i = s.index(after: i)
            }
        }
        return nil
    }

    /// Find closing double quote, handling backslash escapes
    private static func findClosingDoubleQuote(_ s: String, startAfter: String.Index) -> String.Index? {
        var i = s.index(after: startAfter)
        while i < s.endIndex {
            if s[i] == "\\" {
                // Skip next character (escaped)
                i = s.index(after: i)
                if i < s.endIndex {
                    i = s.index(after: i)
                }
            } else if s[i] == "\"" {
                return i
            } else {
                i = s.index(after: i)
            }
        }
        return nil
    }

    private static func commandMatchesPattern(_ command: String, pattern: String) -> Bool {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespaces)

        // Extract command basename for matching (handles quoted paths like '/My App/opencode')
        let commandBasename = parseLeadingExecutableBasename(command)
        // Reconstruct command with basename: find where args start after the executable
        let commandWithBasename: String = {
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return commandBasename }
            let firstChar = trimmed.first!
            var afterExec: String.Index?
            if firstChar == "'" {
                if let close = findClosingSingleQuote(trimmed, startAfter: trimmed.startIndex) {
                    afterExec = trimmed.index(after: close)
                }
            } else if firstChar == "\"" {
                if let close = findClosingDoubleQuote(trimmed, startAfter: trimmed.startIndex) {
                    afterExec = trimmed.index(after: close)
                }
            } else if let space = trimmed.firstIndex(where: { $0.isWhitespace }) {
                afterExec = space
            }
            if let afterExec, afterExec < trimmed.endIndex {
                let rest = trimmed[afterExec...].trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? commandBasename : "\(commandBasename) \(rest)"
            }
            return commandBasename
        }()

        // Prefix match: "opencode *" matches "opencode", "/usr/bin/opencode --flag", etc.
        // Also handles tab as argument separator for robustness
        if trimmedPattern.hasSuffix(" *") {
            let prefix = String(trimmedPattern.dropLast(2))
            // Match against both full path command and basename-only version
            // Check for space or tab as argument separator
            return command == prefix ||
                   command.hasPrefix(prefix + " ") || command.hasPrefix(prefix + "\t") ||
                   commandWithBasename == prefix ||
                   commandWithBasename.hasPrefix(prefix + " ") || commandWithBasename.hasPrefix(prefix + "\t")
        }

        // Exact match (also check basename version)
        return command == trimmedPattern || commandWithBasename == trimmedPattern
    }
}

// MARK: - Foreground Process Detection Cache

/// Cache for foreground process detection results to avoid blocking main thread.
/// Call `refresh(ttyNames:)` periodically from a background queue, then read
/// cached values synchronously via `cachedCommandLine(forTTY:)`.
final class SessionForegroundProcessCache {
    static let shared = SessionForegroundProcessCache()

    private let queue = DispatchQueue(label: "com.cmux.foreground-process-cache", qos: .utility)
    private var cache: [String: String] = [:]  // ttyName -> commandLine
    private var unfairLock = os_unfair_lock()

    private init() {}

    /// Refresh cache for the given TTY names. Runs on internal background queue.
    /// Only caches commands that pass the allowlist to avoid persisting secrets.
    func refresh(ttyNames: [String]) {
        queue.async { [self] in
            var newCache: [String: String] = [:]
            for ttyName in ttyNames {
                let normalizedTTY = Self.normalizeTTYName(ttyName)
                if let detected = SessionForegroundProcessDetector.detect(forTTY: normalizedTTY),
                   let commandLine = detected.commandLine {
                    let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if SessionRestoreCommandSettings.isCommandAllowed(trimmed) {
                        newCache[normalizedTTY] = trimmed
                    }
                }
            }
            os_unfair_lock_lock(&unfairLock)
            cache = newCache
            os_unfair_lock_unlock(&unfairLock)
        }
    }

    /// Refresh cache synchronously with timeout. Falls back to existing cache if timeout exceeded.
    /// Uses a bounded wait to prevent quit from stalling indefinitely on slow ps/sysctl calls.
    func refreshSync(ttyNames: [String], timeout: TimeInterval = 2.0) {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [self] in
            var newCache: [String: String] = [:]
            for ttyName in ttyNames {
                let normalizedTTY = Self.normalizeTTYName(ttyName)
                if let detected = SessionForegroundProcessDetector.detect(forTTY: normalizedTTY),
                   let commandLine = detected.commandLine {
                    let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if SessionRestoreCommandSettings.isCommandAllowed(trimmed) {
                        newCache[normalizedTTY] = trimmed
                    }
                }
            }
            os_unfair_lock_lock(&unfairLock)
            cache = newCache
            os_unfair_lock_unlock(&unfairLock)
            semaphore.signal()
        }
        // Wait with timeout; if exceeded, we use whatever was in cache before
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    /// Get cached command line for a TTY. Safe to call from main thread.
    func cachedCommandLine(forTTY ttyName: String) -> String? {
        let normalizedTTY = Self.normalizeTTYName(ttyName)
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return cache[normalizedTTY]
    }

    /// Normalize TTY name for consistent cache keying (strips /dev/ prefix)
    private static func normalizeTTYName(_ ttyName: String) -> String {
        let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/dev/") {
            return String(trimmed.dropFirst(5))
        }
        return trimmed
    }

    /// Clear the cache (e.g., on app termination).
    func clear() {
        os_unfair_lock_lock(&unfairLock)
        cache.removeAll()
        os_unfair_lock_unlock(&unfairLock)
    }
}

// MARK: - Foreground Process Detection

enum SessionForegroundProcessDetector {
    private static let psPath = "/bin/ps"

    struct ForegroundProcess {
        let pid: Int32
        let executableName: String
        let commandLine: String?
    }

    /// Detect the foreground process running in a TTY.
    /// Returns nil if no foreground process or only shell is running.
    static func detect(forTTY ttyName: String) -> ForegroundProcess? {
        let normalizedTTY = normalizeTTYName(ttyName)
        guard !normalizedTTY.isEmpty else { return nil }

        let processes = processSnapshots(forTTY: normalizedTTY)
        guard let foreground = processes.first(where: { isForegroundProcess($0, ttyName: normalizedTTY) }) else {
            return nil
        }

        // Skip if foreground is just a shell
        let shellNames = [
            "zsh", "bash", "sh", "fish", "tcsh", "ksh", "dash",  // POSIX-ish shells
            "csh",                                               // C shell
            "pwsh", "powershell",                                // PowerShell
            "nu", "nushell",                                     // Nushell
            "elvish", "xonsh", "oil", "osh",                     // Alternative shells
            "rc", "es",                                          // Plan 9 shells
        ]
        if shellNames.contains(foreground.executableName) {
            return nil
        }

        let commandLine = commandLineString(forPID: foreground.pid)

        return ForegroundProcess(
            pid: foreground.pid,
            executableName: foreground.executableName,
            commandLine: commandLine
        )
    }

    private struct ProcessSnapshot {
        let pid: Int32
        let pgid: Int32
        let tpgid: Int32
        let tty: String
        let executableName: String
    }

    private static func normalizeTTYName(_ ttyName: String) -> String {
        let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/dev/") {
            return String(trimmed.dropFirst(5))
        }
        return trimmed
    }

    private static func isForegroundProcess(_ process: ProcessSnapshot, ttyName: String) -> Bool {
        normalizeTTYName(process.tty) == normalizeTTYName(ttyName) &&
            process.tpgid > 0 &&
            process.pgid == process.tpgid
    }

    private static func processSnapshots(forTTY ttyName: String) -> [ProcessSnapshot] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: psPath)
        process.arguments = ["-ww", "-t", ttyName, "-o", "pid=,pgid=,tpgid=,tty=,ucomm="]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output
            .split(separator: "\n")
            .compactMap(parseProcessSnapshot)
    }

    private static func parseProcessSnapshot(_ line: Substring) -> ProcessSnapshot? {
        let parts = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
        guard parts.count == 5,
              let pid = Int32(parts[0]),
              let pgid = Int32(parts[1]),
              let tpgid = Int32(parts[2]) else {
            return nil
        }

        return ProcessSnapshot(
            pid: pid,
            pgid: pgid,
            tpgid: tpgid,
            tty: String(parts[3]),
            executableName: String(parts[4]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private static func commandLineString(forPID pid: Int32) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let success = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &size, nil, 0) == 0
        }
        guard success else { return nil }

        // KERN_PROCARGS2 layout: argc (4 bytes), exec path, null-terminated argv strings
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }

        // Skip argc and find first null (end of exec path)
        var offset = 4
        while offset < buffer.count && buffer[offset] != 0 {
            offset += 1
        }
        // Skip nulls between exec path and argv[0]
        while offset < buffer.count && buffer[offset] == 0 {
            offset += 1
        }

        // Extract argv strings by finding null-separated byte runs and decoding as UTF-8
        // IMPORTANT: Count ALL arguments including empty strings to avoid scanning past argv
        // into environment variables. An empty argv entry (two consecutive nulls) must still
        // be counted toward argc.
        // If any argument fails UTF-8 decoding, abort entirely to avoid restoring a
        // materially different command (e.g., "tool <bad-bytes> --flag" → "tool --flag").
        var args: [String] = []
        var argCount = 0
        var start = offset
        for i in offset...buffer.count {
            let byte: UInt8 = i < buffer.count ? buffer[i] : 0
            if byte == 0 {
                // Always count this as an argument, even if empty
                argCount += 1
                if i > start {
                    let slice = Array(buffer[start..<i])
                    guard let s = String(bytes: slice, encoding: .utf8) else {
                        // Abort on first UTF-8 decode failure
                        return nil
                    }
                    args.append(s)
                }
                // Empty strings (i == start) are counted but not added to args
                if argCount >= Int(argc) { break }
                start = i + 1
            }
        }

        guard !args.isEmpty else { return nil }

        // Keep full path to preserve exact executable location (e.g., /opt/mycompany/tool)
        // Shell-quote arguments that contain spaces, quotes, or special chars
        let quotedArgs = args.map { shellQuoteIfNeeded($0) }
        return quotedArgs.joined(separator: " ")
    }

    /// Shell-quote a string if it contains spaces, quotes, or shell metacharacters.
    /// Uses single quotes with escaped single quotes for safety.
    private static func shellQuoteIfNeeded(_ s: String) -> String {
        // Characters that require quoting in shell
        let needsQuoting = s.contains { c in
            c.isWhitespace || c == "'" || c == "\"" || c == "\\" ||
            c == "$" || c == "`" || c == "!" || c == "*" || c == "?" ||
            c == "[" || c == "]" || c == "(" || c == ")" || c == "{" ||
            c == "}" || c == "<" || c == ">" || c == "|" || c == "&" ||
            c == ";" || c == "#" || c == "~"
        }
        guard needsQuoting else { return s }
        // Use single quotes, escaping any embedded single quotes as '\''
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
