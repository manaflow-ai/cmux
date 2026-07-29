import Foundation

/// What happened in a single history timeline entry.
///
/// Persisted kinds (workspace/window lifecycle) are recorded by
/// ``VaultHistoryEventLog`` as they happen; `sessionActivity` events are
/// derived at read time from the Vault session index and never written to
/// the history store.
enum VaultHistoryEventKind: String, Codable, CaseIterable, Sendable {
    case workspaceCreated
    case workspaceRenamed
    case workspaceClosed
    case windowOpened
    case windowClosed
    case sessionActivity

    /// Localized label describing the event kind, used for rows and
    /// group-by-type section headers.
    var label: String {
        switch self {
        case .workspaceCreated:
            return String(localized: "vaultHistory.kind.workspaceCreated", defaultValue: "Workspace created")
        case .workspaceRenamed:
            return String(localized: "vaultHistory.kind.workspaceRenamed", defaultValue: "Workspace renamed")
        case .workspaceClosed:
            return String(localized: "vaultHistory.kind.workspaceClosed", defaultValue: "Workspace closed")
        case .windowOpened:
            return String(localized: "vaultHistory.kind.windowOpened", defaultValue: "Window opened")
        case .windowClosed:
            return String(localized: "vaultHistory.kind.windowClosed", defaultValue: "Window closed")
        case .sessionActivity:
            return String(localized: "vaultHistory.kind.sessionActivity", defaultValue: "Agent session")
        }
    }

    var symbolName: String {
        switch self {
        case .workspaceCreated: return "plus.square"
        case .workspaceRenamed: return "pencil"
        case .workspaceClosed: return "xmark.square"
        case .windowOpened: return "macwindow.badge.plus"
        case .windowClosed: return "macwindow"
        case .sessionActivity: return "sparkles"
        }
    }
}

/// Identity of the thing an event is about. All fields are optional; each
/// event kind fills the ones that apply. Group-by-workspace/window/agent
/// read these fields, so a missing field lands the event in the shared
/// "Other" bucket for that grouping.
struct VaultHistorySubject: Hashable, Codable, Sendable {
    var workspaceId: UUID?
    var windowId: UUID?
    /// Recently-closed record that can restore this workspace or window.
    var closedItemId: UUID?
    /// Native agent session identifier for `sessionActivity` events.
    var sessionId: String?
    /// `SessionAgent` raw value for `sessionActivity` events.
    var agent: String?
    /// User-facing agent name captured from the session index.
    var agentDisplayName: String?
    /// Working directory associated with the subject, when known.
    var directory: String?

    init(
        workspaceId: UUID? = nil,
        windowId: UUID? = nil,
        closedItemId: UUID? = nil,
        sessionId: String? = nil,
        agent: String? = nil,
        agentDisplayName: String? = nil,
        directory: String? = nil
    ) {
        self.workspaceId = workspaceId
        self.windowId = windowId
        self.closedItemId = closedItemId
        self.sessionId = sessionId
        self.agent = agent
        self.agentDisplayName = agentDisplayName
        self.directory = directory
    }
}

/// One entry in the unified History timeline.
///
/// The model is deliberately flat and locale-independent: display strings
/// (kind labels, "N workspaces" details) are derived in the UI layer so a
/// persisted event renders correctly after a language change.
struct VaultHistoryEvent: Identifiable, Hashable, Codable, Sendable {
    /// Stable identity. Recorded events use a fresh UUID string; derived
    /// session events reuse the session entry id so re-derivation is stable.
    let id: String
    let timestamp: Date
    let kind: VaultHistoryEventKind
    /// Display title of the subject at event time (workspace or session title).
    let title: String
    /// Previous title, set for `workspaceRenamed`.
    let previousTitle: String?
    /// Number of workspaces involved, set for window events.
    let workspaceCount: Int?
    let subject: VaultHistorySubject

    init(
        id: String = UUID().uuidString,
        timestamp: Date,
        kind: VaultHistoryEventKind,
        title: String,
        previousTitle: String? = nil,
        workspaceCount: Int? = nil,
        subject: VaultHistorySubject = VaultHistorySubject()
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.previousTitle = previousTitle
        self.workspaceCount = workspaceCount
        self.subject = subject
    }
}
