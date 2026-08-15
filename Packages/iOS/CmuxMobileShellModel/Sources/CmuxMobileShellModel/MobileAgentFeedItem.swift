public import Foundation

/// The cross-Mac stable identity of one agent-feed row.
public struct MobileAgentFeedItemID: Hashable, Comparable, Sendable {
    public let macDeviceID: String
    public let macInstanceTag: String?
    public let itemID: String

    public init(macDeviceID: String, macInstanceTag: String?, itemID: String) {
        self.macDeviceID = macDeviceID
        self.macInstanceTag = macInstanceTag
        self.itemID = itemID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.macDeviceID != rhs.macDeviceID {
            return lhs.macDeviceID < rhs.macDeviceID
        }
        if lhs.macInstanceTag != rhs.macInstanceTag {
            return (lhs.macInstanceTag ?? "") < (rhs.macInstanceTag ?? "")
        }
        return lhs.itemID < rhs.itemID
    }
}

/// The renderable kinds of one agent-feed row. Raw values are the Mac's
/// `WorkstreamKind` wire names (camelCase). Unknown wire kinds map to
/// ``unsupported`` so newer Macs degrade to a visible-but-inert row instead
/// of a dropped one.
public enum MobileAgentFeedItemKind: String, Sendable, Equatable, CaseIterable {
    case permissionRequest
    case exitPlan
    case question
    case toolUse
    case toolResult
    case userPrompt
    case assistantMessage
    case stop
    case todos
    case unsupported

    /// Whether a pending row of this kind can be answered from the Feed.
    public var isActionable: Bool {
        switch self {
        case .permissionRequest, .exitPlan, .question:
            return true
        case .toolUse, .toolResult, .userPrompt, .assistantMessage, .stop, .todos, .unsupported:
            return false
        }
    }
}

/// The lifecycle state of one agent-feed row.
public enum MobileAgentFeedItemStatus: Sendable, Equatable {
    case pending
    case resolved(MobileAgentFeedDecision)
    case expired
    case telemetry

    public var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

/// The decision recorded on a resolved row.
public struct MobileAgentFeedDecision: Sendable, Equatable {
    /// The decision family (`permission`, `exit_plan`, `question`).
    public let kind: String
    /// The chosen mode for permission and exit-plan decisions.
    public let mode: String?
    /// The chosen option ids or free text for question decisions.
    public let selections: [String]
    /// The revise feedback for exit-plan decisions.
    public let feedback: String?

    public init(
        kind: String,
        mode: String? = nil,
        selections: [String] = [],
        feedback: String? = nil
    ) {
        self.kind = kind
        self.mode = mode
        self.selections = selections
        self.feedback = feedback
    }
}

/// One question prompt of a question row.
public struct MobileAgentFeedQuestion: Sendable, Equatable {
    public let id: String
    public let header: String?
    public let prompt: String
    public let multiSelect: Bool
    public let options: [MobileAgentFeedQuestionOption]

    public init(
        id: String,
        header: String? = nil,
        prompt: String,
        multiSelect: Bool = false,
        options: [MobileAgentFeedQuestionOption] = []
    ) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.multiSelect = multiSelect
        self.options = options
    }
}

/// One selectable option of a question prompt.
public struct MobileAgentFeedQuestionOption: Sendable, Equatable {
    public let id: String
    public let label: String
    public let description: String?

    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }
}

/// Nearby conversation context carried with a row: the user's ask and the
/// agent's own words around the event, rendered inline in the Feed.
public struct MobileAgentFeedContext: Sendable, Equatable {
    public let lastUserMessage: String?
    public let assistantPreamble: String?
    public let planSummary: String?
    public let toolSummary: String?
    public let permissionMode: String?

    public init(
        lastUserMessage: String? = nil,
        assistantPreamble: String? = nil,
        planSummary: String? = nil,
        toolSummary: String? = nil,
        permissionMode: String? = nil
    ) {
        self.lastUserMessage = lastUserMessage
        self.assistantPreamble = assistantPreamble
        self.planSummary = planSummary
        self.toolSummary = toolSummary
        self.permissionMode = permissionMode
    }

    public var isEmpty: Bool {
        lastUserMessage == nil
            && assistantPreamble == nil
            && planSummary == nil
            && toolSummary == nil
            && permissionMode == nil
    }
}

/// An immutable agent-feed row ready for presentation by the mobile shell.
public struct MobileAgentFeedItem: Identifiable, Equatable, Sendable {
    /// The cross-Mac stable identity used by list diffing and action routing.
    public let id: MobileAgentFeedItemID
    /// The stable device identifier of the Mac that owns the workstream.
    public let macDeviceID: String
    /// The owning pairing's app-instance tag, or `nil` for a legacy pairing.
    public let macInstanceTag: String?
    /// The owning Mac's user-facing name.
    public let macDisplayName: String
    /// The Mac-local item identifier.
    public let itemID: String
    /// The owning workstream (`<agent>-<sessionId>`).
    public let workstreamID: String
    /// The emitting agent's wire name (`claude`, `codex`, ...).
    public let source: String
    public let kind: MobileAgentFeedItemKind
    public let status: MobileAgentFeedItemStatus
    public let createdAt: Date
    public let updatedAt: Date
    public let title: String?
    public let cwd: String?
    /// The reply correlation id for actionable rows.
    public let requestID: String?
    public let toolName: String?
    public let toolInput: String?
    public let toolResult: String?
    public let toolResultIsError: Bool
    public let plan: String?
    public let planSummary: String?
    /// The exit-plan approval mode preselected by the agent.
    public let defaultExitPlanMode: String?
    public let questions: [MobileAgentFeedQuestion]
    /// The free text of user-prompt and assistant-message rows.
    public let text: String?
    /// The stop reason for turn-complete rows, when the agent gave one.
    public let stopReason: String?
    /// The Mac-local workspace identifier to route replies to, when resolved.
    public let remoteWorkspaceID: String?
    /// The Mac-local pane or terminal-surface identifier, when resolved.
    public let remoteSurfaceID: String?
    public let workspaceTitle: String?
    public let surfaceTitle: String?
    public let context: MobileAgentFeedContext?
    /// The current reachability of the owning Mac.
    public let connectionStatus: MobileMacConnectionStatus

    /// Whether the row is awaiting a decision the user can take from the Feed.
    public var needsInput: Bool {
        status.isPending && kind.isActionable && requestID != nil
    }

    /// Whether the row supports a free-text reply routed to its terminal.
    public var supportsTerminalReply: Bool {
        kind == .stop && remoteWorkspaceID != nil && remoteSurfaceID != nil
    }

    public init(
        macDeviceID: String,
        macInstanceTag: String? = nil,
        macDisplayName: String,
        itemID: String,
        workstreamID: String,
        source: String,
        kind: MobileAgentFeedItemKind,
        status: MobileAgentFeedItemStatus,
        createdAt: Date,
        updatedAt: Date,
        title: String? = nil,
        cwd: String? = nil,
        requestID: String? = nil,
        toolName: String? = nil,
        toolInput: String? = nil,
        toolResult: String? = nil,
        toolResultIsError: Bool = false,
        plan: String? = nil,
        planSummary: String? = nil,
        defaultExitPlanMode: String? = nil,
        questions: [MobileAgentFeedQuestion] = [],
        text: String? = nil,
        stopReason: String? = nil,
        remoteWorkspaceID: String? = nil,
        remoteSurfaceID: String? = nil,
        workspaceTitle: String? = nil,
        surfaceTitle: String? = nil,
        context: MobileAgentFeedContext? = nil,
        connectionStatus: MobileMacConnectionStatus
    ) {
        self.id = MobileAgentFeedItemID(
            macDeviceID: macDeviceID,
            macInstanceTag: macInstanceTag,
            itemID: itemID
        )
        self.macDeviceID = macDeviceID
        self.macInstanceTag = macInstanceTag
        self.macDisplayName = macDisplayName
        self.itemID = itemID
        self.workstreamID = workstreamID
        self.source = source
        self.kind = kind
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.cwd = cwd
        self.requestID = requestID
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolResult = toolResult
        self.toolResultIsError = toolResultIsError
        self.plan = plan
        self.planSummary = planSummary
        self.defaultExitPlanMode = defaultExitPlanMode
        self.questions = questions
        self.text = text
        self.stopReason = stopReason
        self.remoteWorkspaceID = remoteWorkspaceID
        self.remoteSurfaceID = remoteSurfaceID
        self.workspaceTitle = workspaceTitle
        self.surfaceTitle = surfaceTitle
        self.context = context
        self.connectionStatus = connectionStatus
    }

    /// Returns the same row with updated lifecycle and reachability state.
    public func updating(
        status: MobileAgentFeedItemStatus? = nil,
        updatedAt: Date? = nil,
        connectionStatus: MobileMacConnectionStatus? = nil
    ) -> MobileAgentFeedItem {
        MobileAgentFeedItem(
            macDeviceID: macDeviceID,
            macInstanceTag: macInstanceTag,
            macDisplayName: macDisplayName,
            itemID: itemID,
            workstreamID: workstreamID,
            source: source,
            kind: kind,
            status: status ?? self.status,
            createdAt: createdAt,
            updatedAt: updatedAt ?? self.updatedAt,
            title: title,
            cwd: cwd,
            requestID: requestID,
            toolName: toolName,
            toolInput: toolInput,
            toolResult: toolResult,
            toolResultIsError: toolResultIsError,
            plan: plan,
            planSummary: planSummary,
            defaultExitPlanMode: defaultExitPlanMode,
            questions: questions,
            text: text,
            stopReason: stopReason,
            remoteWorkspaceID: remoteWorkspaceID,
            remoteSurfaceID: remoteSurfaceID,
            workspaceTitle: workspaceTitle,
            surfaceTitle: surfaceTitle,
            context: context,
            connectionStatus: connectionStatus ?? self.connectionStatus
        )
    }
}
