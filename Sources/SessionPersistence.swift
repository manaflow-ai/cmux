import CMUXAgentLaunch
import CoreGraphics
import CmuxCore
import Foundation
import Bonsplit
import CmuxWorkspaces
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

enum SessionSnapshotSchema {
    static let currentVersion = 1
}

enum SessionPersistencePolicy {
    static let sidebarMinimumWidthKey = "sidebarMinimumWidth"
    // Keep the default equal to the minimum so a fresh sidebar starts at the
    // minimum width. The titlebar title tracks the sidebar's actual width only
    // when it is wider than the minimum, so a default above the minimum would make
    // the folder/title shift when toggling the sidebar at the default width.
    static let defaultSidebarWidth: Double = 216
    static let defaultMinimumSidebarWidth: Double = 216
    static let minimumSidebarWidth: Double = 216
    static let sidebarMinimumWidthRange: ClosedRange<Double> = 120...260
    static let maximumSidebarWidth: Double = 600
    static let minimumWindowWidth: Double = 300
    static let minimumWindowHeight: Double = 200
    static let autosaveInterval: TimeInterval = 8.0
    static let maxWindowsPerSnapshot: Int = 12
    static let maxWorkspacesPerWindow: Int = 128
    static let maxPanelsPerWorkspace: Int = 512

    static func sanitizedSidebarWidth(_ candidate: Double?, defaults: UserDefaults = .standard) -> Double {
        let resolvedMinimum = resolvedMinimumSidebarWidth(defaults: defaults)
        let fallback = min(max(defaultSidebarWidth, resolvedMinimum), maximumSidebarWidth)
        guard let candidate, candidate.isFinite else { return fallback }
        return min(max(candidate, resolvedMinimum), maximumSidebarWidth)
    }

    static func resolvedMinimumSidebarWidth(defaults: UserDefaults = .standard) -> Double {
        guard let candidate = storedSidebarMinimumWidth(defaults: defaults) else {
            return defaultMinimumSidebarWidth
        }
        return sanitizedMinimumSidebarWidth(candidate)
    }

    static func sanitizedMinimumSidebarWidth(_ candidate: Double) -> Double {
        guard candidate.isFinite else { return defaultMinimumSidebarWidth }
        return min(max(candidate, sidebarMinimumWidthRange.lowerBound), sidebarMinimumWidthRange.upperBound)
    }

    private static func storedSidebarMinimumWidth(defaults: UserDefaults) -> Double? {
        if let value = defaults.object(forKey: sidebarMinimumWidthKey) as? NSNumber {
            return value.doubleValue
        }
        if let value = defaults.string(forKey: sidebarMinimumWidthKey) {
            return Double(value)
        }
        return nil
    }
}

// `SessionRestorePolicy` (the launch-time automated-test detection and
// session-restore gating decision over ProcessInfo env + CommandLine args) now
// lives in CmuxWorkspaces (Session/SessionRestorePolicy.swift) as a real value
// type with constructor-injected arguments/environment. It is imported via
// `import CmuxWorkspaces`.

// `SurfaceResumeApprovalPolicy` (the manual/prompt/auto resume disposition) now
// lives in CmuxWorkspaces (Session/SurfaceResumeApprovalPolicy.swift) as a public
// value type, imported via `import CmuxWorkspaces`.

nonisolated struct SurfaceResumeBindingSnapshot: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case name
        case kind
        case command
        case cwd
        case checkpointId
        case source
        case environment
        case autoResume
        case approvalPolicy
        case approvalRecordId
        case updatedAt
    }

    var name: String?
    var kind: String?
    var command: String
    var cwd: String?
    var checkpointId: String?
    var source: String?
    var environment: [String: String]?
    var autoResume: Bool?
    var approvalPolicy: SurfaceResumeApprovalPolicy?
    var approvalRecordId: String?
    var updatedAt: TimeInterval

    init(
        name: String? = nil,
        kind: String? = nil,
        command: String,
        cwd: String? = nil,
        checkpointId: String? = nil,
        source: String? = nil,
        environment: [String: String]? = nil,
        autoResume: Bool? = nil,
        approvalPolicy: SurfaceResumeApprovalPolicy? = nil,
        approvalRecordId: String? = nil,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        let normalizedCwd = Self.normalized(cwd)
        let normalizedSource = Self.normalized(source)
        self.name = Self.normalized(name)
        self.kind = Self.normalized(kind)
        self.command = Self.sanitizedStartupCommand(
            command,
            cwd: normalizedCwd,
            source: normalizedSource
        )
        self.cwd = normalizedCwd
        self.checkpointId = Self.normalized(checkpointId)
        self.source = normalizedSource
        self.environment = Self.normalizedEnvironment(environment)
        self.autoResume = autoResume
        self.approvalPolicy = approvalPolicy
        self.approvalRecordId = Self.normalized(approvalRecordId)
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name),
            kind: try container.decodeIfPresent(String.self, forKey: .kind),
            command: try container.decode(String.self, forKey: .command),
            cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
            checkpointId: try container.decodeIfPresent(String.self, forKey: .checkpointId),
            source: try container.decodeIfPresent(String.self, forKey: .source),
            environment: try container.decodeIfPresent([String: String].self, forKey: .environment),
            autoResume: try container.decodeIfPresent(Bool.self, forKey: .autoResume),
            approvalPolicy: try container.decodeIfPresent(SurfaceResumeApprovalPolicy.self, forKey: .approvalPolicy),
            approvalRecordId: try container.decodeIfPresent(String.self, forKey: .approvalRecordId),
            updatedAt: try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt)
                ?? Date().timeIntervalSince1970
        )
    }

    var isProcessDetected: Bool {
        source == "process-detected"
    }

    var isAgentHookBinding: Bool {
        source == "agent-hook"
    }

    var isCLIBinding: Bool {
        source == "cli"
    }

    var allowsAutomaticResume: Bool {
        autoResume == true
    }

    func shouldYieldToDetectedSurfaceResumeBinding(_ detectedBinding: SurfaceResumeBindingSnapshot) -> Bool {
        detectedBinding.isProcessDetected && (isProcessDetected || isAgentHookBinding)
    }

    static let maxInlineStartupInputBytes = SessionRestorableAgentSnapshot.maxInlineStartupInputBytes

    var startupInput: String? {
        inlineStartupInput
    }

    var inlineStartupInput: String? {
        let trimmed = startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let environment, !environment.isEmpty else {
            return trimmed + "\n"
        }
        let assignments = environment.keys.sorted().compactMap { key -> String? in
            guard let value = environment[key] else { return nil }
            return "\(key)=\(value)"
        }
        let argv = ["/usr/bin/env"] + assignments + ["/bin/zsh", "-lc", trimmed]
        return argv.map(Self.shellSingleQuoted).joined(separator: " ") + "\n"
    }

    private var startupCommand: String {
        Self.sanitizedStartupCommand(command, cwd: cwd, source: source)
    }

    private static func sanitizedStartupCommand(
        _ command: String,
        cwd: String?,
        source: String?
    ) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source == "agent-hook" else { return trimmed }
        return TerminalStartupWorkingDirectoryPrefix().replacingRequiredChangeDirectoryPrefix(
            in: trimmed,
            workingDirectory: cwd
        )
    }

    func startupInputWithLauncherScript(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        allowLauncherScript: Bool = true
    ) -> String? {
        guard let inlineInput = inlineStartupInput else { return nil }
        guard inlineInput.utf8.count > Self.maxInlineStartupInputBytes else {
            return inlineInput
        }
        guard allowLauncherScript else { return inlineInput }
        guard let scriptURL = SurfaceResumeBindingScriptStore.writeLauncherScript(
            inlineInput: inlineInput,
            binding: self,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        ) else {
            return nil
        }

        let scriptInput = "/bin/zsh \(Self.shellSingleQuoted(scriptURL.path))\n"
        return scriptInput.utf8.count <= Self.maxInlineStartupInputBytes ? scriptInput : nil
    }

    func startupCommandWithLauncherScript(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        guard let inlineInput = inlineStartupInput,
              let scriptURL = SurfaceResumeBindingScriptStore.writeLauncherScript(
                  inlineInput: inlineInput,
                  binding: self,
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory,
                  returnToLoginShell: true
              ) else {
            return nil
        }
        return "/bin/zsh \(Self.shellSingleQuoted(scriptURL.path))"
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private static func normalizedEnvironment(_ environment: [String: String]?) -> [String: String]? {
        guard let environment else { return nil }
        let normalized = environment.reduce(into: [String: String]()) { result, item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !isSensitiveEnvironmentKey(key) else { return }
            guard isSafeEnvironmentValue(item.value) else { return }
            result[key] = item.value
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func isSafeEnvironmentValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func isSensitiveEnvironmentKey(_ key: String) -> Bool {
        let uppercasedKey = key.uppercased()
        let sensitiveFragments = [
            "API_KEY",
            "ACCESS_KEY",
            "AUTH_TOKEN",
            "BEARER_TOKEN",
            "PRIVATE_KEY",
            "PASSWORD",
            "PASSWD",
            "SECRET",
            "TOKEN",
            "CREDENTIAL",
            "COOKIE",
        ]
        return sensitiveFragments.contains { uppercasedKey.contains($0) }
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension SurfaceResumeBindingSnapshot: WorkspaceSurfaceResumeBinding {
    var requiresPromptApproval: Bool {
        approvalPolicy == .prompt
    }
}

/// Conforms the persisted binding snapshot to the CmuxWorkspaces resolution
/// seam so `SessionRestoreCoordinator` can decide stored-vs-process-detected
/// outcomes without importing this wire type. Both witnesses
/// (`isProcessDetected`, `shouldYieldToDetectedSurfaceResumeBinding(_:)`) are
/// already declared on the struct above, so the conformance is satisfied as-is.
extension SurfaceResumeBindingSnapshot: SurfaceResumeBindingResolving {}

// The surface-resume approval value cluster now lives in CmuxWorkspaces
// (Session/SurfaceResumeApprovalRecord.swift, plus the command-canonicalization
// and approval-signature extensions in String+/Data+SurfaceResume*.swift). The
// record's `matches(_:)` reads the binding through the `WorkspaceSurfaceResumeBinding`
// seam; all are imported via `import CmuxWorkspaces`.

private enum SurfaceResumeBindingScriptStore {
    private static let directoryName = "cmux-surface-resume"
    private static let scriptTTL: TimeInterval = 24 * 60 * 60

    static func writeLauncherScript(
        inlineInput: String,
        binding: SurfaceResumeBindingSnapshot,
        fileManager: FileManager,
        temporaryDirectory: URL,
        returnToLoginShell: Bool = false
    ) -> URL? {
        let directoryURL = temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            pruneOldScripts(in: directoryURL, fileManager: fileManager)

            let prefix = safeFilenamePrefix(binding: binding)
            let scriptURL = directoryURL.appendingPathComponent(
                "\(prefix)-\(UUID().uuidString).zsh",
                isDirectory: false
            )
            var lines = [
                "#!/bin/zsh",
                "rm -f -- \"$0\" 2>/dev/null || true"
            ]
            if returnToLoginShell {
                lines.append(contentsOf: TerminalStartupReturnShellScript().commandThenReturnLines(
                    command: inlineInput,
                    workingDirectory: binding.cwd
                ))
            } else {
                lines.append(inlineInput)
            }
            let contents = lines.joined(separator: "\n") + "\n"
            try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL
        } catch {
            return nil
        }
    }

    private static func safeFilenamePrefix(binding: SurfaceResumeBindingSnapshot) -> String {
        let rawPrefix = binding.kind ?? binding.source ?? "surface-resume"
        let safePrefix = rawPrefix
            .prefix(24)
            .map { character -> Character in
                character.isLetter || character.isNumber || character == "-" ? character : "_"
            }
        return safePrefix.isEmpty ? "surface-resume" : String(safePrefix)
    }

    private static func pruneOldScripts(in directoryURL: URL, fileManager: FileManager) {
        guard let scriptURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-scriptTTL)
        for scriptURL in scriptURLs where scriptURL.pathExtension == "zsh" {
            guard let values = try? scriptURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff else {
                continue
            }
            try? fileManager.removeItem(at: scriptURL)
        }
    }
}

struct SessionTerminalPanelSnapshot: Codable, Sendable {
    var workingDirectory: String?
    var scrollback: String?
    var agent: SessionRestorableAgentSnapshot?
    var tmuxStartCommand: String?
    var hibernation: SessionAgentHibernationSnapshot?
    var resumeBinding: SurfaceResumeBindingSnapshot?
    var textBoxDraft: SessionTextBoxInputDraftSnapshot?
    var isRemoteTerminal: Bool?
    var remotePTYSessionID: String?
    /// Whether the agent process was actively running when this snapshot was captured.
    /// Nil means unknown (legacy snapshots); treated as true for backwards compatibility.
    var wasAgentRunning: Bool?

    init(
        workingDirectory: String? = nil,
        scrollback: String? = nil,
        agent: SessionRestorableAgentSnapshot? = nil,
        tmuxStartCommand: String? = nil,
        hibernation: SessionAgentHibernationSnapshot? = nil,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil,
        textBoxDraft: SessionTextBoxInputDraftSnapshot? = nil,
        isRemoteTerminal: Bool? = nil,
        remotePTYSessionID: String? = nil,
        wasAgentRunning: Bool? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.scrollback = scrollback
        self.agent = agent
        self.tmuxStartCommand = tmuxStartCommand
        self.hibernation = hibernation
        self.resumeBinding = resumeBinding
        self.textBoxDraft = textBoxDraft
        self.isRemoteTerminal = isRemoteTerminal
        self.remotePTYSessionID = remotePTYSessionID
        self.wasAgentRunning = wasAgentRunning
    }
}

extension SessionTerminalPanelSnapshot: WorkspaceSessionRemoteRestoreTerminalSnapshot {}

struct SessionRightSidebarToolPanelSnapshot: Codable, Sendable {
    var mode: RightSidebarMode?

    init(mode: RightSidebarMode?) {
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent(String.self, forKey: .mode)
        self.mode = raw.flatMap { RightSidebarMode(rawValue: $0) }
    }
}

struct SessionNotificationSnapshot: Codable, Sendable {
    var id: UUID
    var title: String
    var subtitle: String
    var body: String
    var createdAt: TimeInterval
    var isRead: Bool
    var paneFlash: Bool?
    var clickAction: TerminalNotificationClickAction?

    init(
        id: UUID,
        title: String,
        subtitle: String,
        body: String,
        createdAt: TimeInterval,
        isRead: Bool,
        paneFlash: Bool? = nil,
        clickAction: TerminalNotificationClickAction? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.clickAction = clickAction
    }

    init(notification: TerminalNotification) {
        self.init(
            id: notification.id,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            createdAt: notification.createdAt.timeIntervalSince1970,
            isRead: notification.isRead,
            paneFlash: notification.paneFlash,
            clickAction: notification.clickAction
        )
    }

    func terminalNotification(tabId: UUID, surfaceId: UUID?, panelId: UUID?) -> TerminalNotification {
        TerminalNotification(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: Date(timeIntervalSince1970: createdAt),
            isRead: isRead,
            paneFlash: paneFlash ?? true,
            clickAction: clickAction
        )
    }
}

struct SessionPanelSnapshot: Codable, Sendable {
    var id: UUID
    var type: PanelType
    var title: String?
    var customTitle: String?
    /// Provenance of `customTitle`. Optional with a `nil` default so snapshots
    /// persisted before provenance existed decode unchanged; restore treats
    /// absent provenance as user-set (the conservative choice for auto-naming).
    var customTitleSource: Workspace.CustomTitleSource? = nil
    var directory: String?
    var isPinned: Bool
    var isManuallyUnread: Bool
    var hasUnreadIndicator: Bool? = nil
    var restoredUnreadContributesToWorkspace: Bool? = nil
    var notifications: [SessionNotificationSnapshot]? = nil
    var gitBranch: SessionGitBranchSnapshot?
    var listeningPorts: [Int]
    var ttyName: String?
    var terminal: SessionTerminalPanelSnapshot?
    var browser: SessionBrowserPanelSnapshot?
    var markdown: SessionMarkdownPanelSnapshot?
    var filePreview: SessionFilePreviewPanelSnapshot?
    var rightSidebarTool: SessionRightSidebarToolPanelSnapshot?
    var agentSession: SessionAgentSessionPanelSnapshot? = nil
    var project: SessionProjectPanelSnapshot?
}

extension SessionPanelSnapshot: WorkspaceSessionRemoteRestorePanelSnapshot {}

// The persisted layout DTOs (SessionSplitOrientation, SessionPaneLayoutSnapshot,
// SessionSplitLayoutSnapshot, SessionWorkspaceLayoutSnapshot, and
// SessionCanvasPaneSnapshot) now live in CmuxWorkspaces/Session/, alongside the
// SessionLayoutPruning/SessionLayoutNodeBuilding seams and the session restore
// coordinator that compute over them. They are imported via `import CmuxWorkspaces`.

struct SessionWorkspaceSnapshot: Codable, Sendable {
    /// Original workspace ID captured when the snapshot comes from a live workspace.
    /// Restore uses this to remap closed-panel history onto the new workspace IDs;
    /// legacy or externally-created snapshots can leave it nil.
    var workspaceId: UUID? = nil
    var processTitle: String
    var customTitle: String?
    /// Provenance of `customTitle`. Optional with a `nil` default so snapshots
    /// persisted before provenance existed decode unchanged; restore treats
    /// absent provenance as user-set (the conservative choice for auto-naming).
    var customTitleSource: Workspace.CustomTitleSource? = nil
    var customDescription: String?
    var customColor: String?
    var isPinned: Bool
    var groupId: UUID? = nil
    var isManuallyUnread: Bool? = nil
    var hasUnreadIndicator: Bool? = nil
    var notifications: [SessionNotificationSnapshot]? = nil
    var terminalScrollBarHidden: Bool?
    var currentDirectory: String
    var focusedPanelId: UUID?
    var layout: SessionWorkspaceLayoutSnapshot
    /// `WorkspaceLayoutMode` raw value; absent in pre-canvas snapshots
    /// (treated as splits).
    var layoutMode: String? = nil
    /// Canvas pane frames in z-order; persisted whenever any exist so
    /// positions survive toggling back to splits across restarts.
    var canvasPanes: [SessionCanvasPaneSnapshot]? = nil
    var panels: [SessionPanelSnapshot]
    var statusEntries: [SessionStatusEntrySnapshot]
    var logEntries: [SessionLogEntrySnapshot]
    var progress: SessionProgressSnapshot?
    var gitBranch: SessionGitBranchSnapshot?
    var remote: SessionRemoteWorkspaceSnapshot?
    /// User-defined per-workspace environment variables (issue #5995). Optional
    /// with a `nil` default so manifests written before this field decode cleanly.
    var environment: [String: String]? = nil
}

extension SessionWorkspaceSnapshot: WorkspaceSessionRemoteRestoreSnapshot {}

// `SessionWorkspaceGroupSnapshot` moved to CmuxWorkspaces
// (Session/SessionWorkspaceGroupSnapshot.swift) so the package-owned snapshot
// assembly/restore math (SessionSnapshotGroupCoordinator) speaks it directly.
// The Codable wire format is unchanged; this file imports it via CmuxWorkspaces.

extension SessionWorkspaceSnapshot {
    var hasRestorablePanels: Bool {
        !panels.isEmpty
    }
}

extension SessionWindowSnapshot {
    var hasRestorablePanels: Bool {
        tabManager.workspaces.contains { $0.hasRestorablePanels }
    }
}

struct SessionTabManagerSnapshot: Codable, Sendable {
    var selectedWorkspaceIndex: Int?
    var workspaces: [SessionWorkspaceSnapshot]
    var workspaceGroups: [SessionWorkspaceGroupSnapshot]? = nil
}

struct SessionWindowSnapshot: Codable, Sendable {
    var windowId: UUID? = nil
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

extension AppSessionSnapshot: SessionSnapshotRepresenting {
    /// Whether the snapshot carries at least one window. The `CmuxSession`
    /// repository treats an empty-window snapshot as unusable (empty states
    /// remove the file instead of writing it), matching the legacy
    /// `!snapshot.windows.isEmpty` usability check.
    var hasWindows: Bool { !windows.isEmpty }
}
