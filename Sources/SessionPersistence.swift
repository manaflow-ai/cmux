import CMUXAgentLaunch
import CoreGraphics
import CmuxCore
import CmuxNotifications
import Foundation
import Bonsplit
import CmuxWorkspaces
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

// The current snapshot schema version (legacy `SessionSnapshotSchema.currentVersion`)
// now lives in CmuxWorkspaces as `SessionSnapshotRepresenting.currentSchemaVersion`,
// a static on the schema seam already owned by the package. The value is unchanged;
// call it as `AppSessionSnapshot.currentSchemaVersion`.

enum SessionPersistencePolicy {
    static let sidebarMinimumWidthKey = "sidebarMinimumWidth"
    // Keep the default equal to the minimum so a fresh sidebar starts at the
    // minimum width. The titlebar title tracks the sidebar's actual width only
    // when it is wider than the minimum, so a default above the minimum would make
    // the folder/title shift when toggling the sidebar at the default width.
    static let defaultSidebarWidth: Double = 240
    static let defaultMinimumSidebarWidth: Double = 240
    static let minimumSidebarWidth: Double = 240
    static let sidebarMinimumWidthRange: ClosedRange<Double> = 120...260
    static let maximumSidebarWidth: Double = 600
    static let minimumWindowWidth: Double = 300
    static let minimumWindowHeight: Double = 200
    static let autosaveInterval: TimeInterval = 8.0
    static let maxWindowsPerSnapshot: Int = 12
    static let maxWorkspacesPerWindow: Int = 128
    static let maxPanelsPerWorkspace: Int = 512
    static let maxScrollbackLinesPerTerminal: Int = 4000
    static let maxScrollbackCharactersPerTerminal: Int = 400_000

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

    static func truncatedScrollback(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if text.count <= maxScrollbackCharactersPerTerminal {
            return text
        }
        let initialStart = text.index(text.endIndex, offsetBy: -maxScrollbackCharactersPerTerminal)
        let safeStart = ansiSafeTruncationStart(in: text, initialStart: initialStart)
        return String(text[safeStart...])
    }

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

        if csiFinalByteIndex(in: text, from: csiMarker, upperBound: initialStart) != nil {
            return initialStart
        }

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

// `SessionRestorePolicy` (the launch-time automated-test detection and
// session-restore gating decision over ProcessInfo env + CommandLine args) now
// lives in CmuxWorkspaces (Session/SessionRestorePolicy.swift) as a real value
// type with constructor-injected arguments/environment. It is imported via
// `import CmuxWorkspaces`.

// `SurfaceResumeApprovalPolicy` (the manual/prompt/auto resume disposition) now
// lives in CmuxWorkspaces (Session/SurfaceResumeApprovalPolicy.swift) as a public
// value type, imported via `import CmuxWorkspaces`.

// `SurfaceResumeBindingSnapshot` (the persisted surface-resume binding wire
// type, its `WorkspaceSurfaceResumeBinding`/`SurfaceResumeBindingResolving`
// conformances, and the private launcher-script store) now lives in
// CmuxWorkspaces (Session/SurfaceResumeBindingSnapshot.swift) as a public value
// type, imported via `import CmuxWorkspaces`. Its `maxInlineStartupInputBytes`
// is the inlined 900-byte constant that mirrors
// `SessionRestorableAgentSnapshot.maxInlineStartupInputBytes`.

// The surface-resume approval value cluster now lives in CmuxWorkspaces
// (Session/SurfaceResumeApprovalRecord.swift, plus the command-canonicalization
// and approval-signature extensions in String+/Data+SurfaceResume*.swift). The
// record's `matches(_:)` reads the binding through the `WorkspaceSurfaceResumeBinding`
// seam; all are imported via `import CmuxWorkspaces`.

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

// `SessionNotificationSnapshot` (the persisted Codable DTO bridging
// `TerminalNotification`, its `init(notification:)` capture, and the
// `terminalNotification(tabId:surfaceId:panelId:)` restore bridge) now lives in
// CmuxNotifications (SessionNotificationSnapshot.swift) as a public value type,
// imported via `import CmuxNotifications`. The Codable wire format is unchanged.

struct SessionPanelSnapshot: Codable, Sendable {
    var id: UUID
    var type: PanelType
    var title: String?
    var customTitle: String?
    /// Provenance of `customTitle`; absent provenance restores as user-set for compatibility.
    var customTitleSource: Workspace.CustomTitleSource? = nil
    var directory: String?
    var directoryIsTrustedRemoteReport: Bool? = nil
    var directoryRequiresRemoteTrust: Bool? = nil
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
    /// Custom right-sidebar tab persisted state (#6430). Optional with a `nil`
    /// default so snapshots persisted before custom sidebars decode unchanged.
    var customSidebar: SessionCustomSidebarPanelSnapshot? = nil
}

/// Persisted state for a custom right-sidebar tab panel (#6430): just its name,
/// which resolves back to the on-disk custom-sidebar definition on restore.
struct SessionCustomSidebarPanelSnapshot: Codable, Sendable { var name: String }

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
    /// Per-display-configuration remembered frames (LRU ring). Optional and
    /// additive so older persisted snapshots decode unchanged.
    var configFrames: [SessionConfigFrameEntry]? = nil
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
