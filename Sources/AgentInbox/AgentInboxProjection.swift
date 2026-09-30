import AppKit
import CMUXAgentLaunch
import CmuxAgentJournal
import Foundation

enum AgentInboxItemKind: String, CaseIterable, Equatable, Sendable {
    case agentMessage
    case permissionRequest
    case planApproval
    case question
    case finishedTurn
}

enum AgentInboxReplyTarget: Equatable, Sendable {
    case agentMessage(surfaceId: String, workspaceId: String?, replyTo: String?)
    case feed(UUID)
    case workstream(String)
}

enum AgentInboxDecisionTarget {
    static func id(for target: AgentInboxReplyTarget?) -> UUID? {
        guard case let .feed(id) = target else { return nil }
        return id
    }
}

enum AgentInboxReplyResolutionPolicy {
    static func shouldApply(
        resolvedWorkstreamID: String,
        selectedItemID: String?
    ) -> Bool {
        guard let selectedItemID else { return false }
        return resolvedWorkstreamID == selectedItemID
    }
}

enum CommandPaletteOverlayState: Equatable, Sendable {
    case closed
    case palette
    case agentInbox

    var isCommandPalettePresented: Bool {
        self != .closed
    }

    var isAgentInboxPresented: Bool {
        self == .agentInbox
    }
}

enum AgentInboxReplyError: Error, Equatable, Sendable {
    case emptyBody
    case missingRecipient
    case unresolvedWorkstream
    case unsupportedTarget
}

enum AgentInboxInteractionPolicy {
    static func shouldMoveSelection(isReplyFieldFocused: Bool) -> Bool {
        !isReplyFieldFocused
    }
}

enum AgentInboxReplyFieldFocusPolicy {
    static func notificationWindow(hostingWindow: NSWindow?, keyWindow _: NSWindow?) -> NSWindow? {
        hostingWindow
    }
}

struct AgentInboxOpenRequest: Equatable, Sendable {
    let generation: Int

    func isCurrent(generation: Int, isPresented: Bool) -> Bool {
        isPresented && self.generation == generation
    }
}

struct AgentInboxReplySubmissionGate: Equatable, Sendable {
    private(set) var isInFlight = false

    mutating func begin() -> Bool {
        guard !isInFlight else { return false }
        isInFlight = true
        return true
    }

    mutating func finish() {
        isInFlight = false
    }
}

struct AgentInboxReadStateStore {
    private static let finishedTurnIDsKey = "agentInbox.finishedTurnIDs"
    static let maxFinishedTurnIDs = 256

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var finishedTurnIDs: Set<String> {
        guard let data = defaults.data(forKey: Self.finishedTurnIDsKey),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        let trimmedIDs = ids.count > Self.maxFinishedTurnIDs
            ? Array(ids.suffix(Self.maxFinishedTurnIDs))
            : ids
        if trimmedIDs.count != ids.count,
           let trimmedData = try? JSONEncoder().encode(trimmedIDs) {
            defaults.set(trimmedData, forKey: Self.finishedTurnIDsKey)
        }
        return Set(trimmedIDs)
    }

    func markFinishedTurnRead(_ id: String) {
        guard !id.isEmpty else { return }
        var ids: [String]
        if let data = defaults.data(forKey: Self.finishedTurnIDsKey),
           let persistedIDs = try? JSONDecoder().decode([String].self, from: data) {
            ids = persistedIDs
        } else {
            ids = []
        }
        ids.removeAll { $0 == id }
        ids.append(id)
        if ids.count > Self.maxFinishedTurnIDs {
            ids.removeFirst(ids.count - Self.maxFinishedTurnIDs)
        }
        guard let data = try? JSONEncoder().encode(ids) else { return }
        defaults.set(data, forKey: Self.finishedTurnIDsKey)
    }
}

enum AgentInboxReplySender {
    static func send(
        body: String,
        senderName: String,
        target: AgentInboxReplyTarget,
        workstreamTarget: FeedJumpResolver.Target?,
        store: AgentMessageStore
    ) throws -> AgentMessage {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw AgentInboxReplyError.emptyBody }

        let recipient: (surfaceId: String, workspaceId: String?, replyTo: String?)
        switch target {
        case let .agentMessage(surfaceId, workspaceId, replyTo):
            guard !surfaceId.isEmpty else { throw AgentInboxReplyError.missingRecipient }
            recipient = (surfaceId, workspaceId, replyTo)
        case .workstream:
            guard let workstreamTarget else {
                throw AgentInboxReplyError.unresolvedWorkstream
            }
            guard !workstreamTarget.surfaceId.isEmpty else {
                throw AgentInboxReplyError.missingRecipient
            }
            recipient = (workstreamTarget.surfaceId, workstreamTarget.workspaceId, nil)
        case .feed:
            throw AgentInboxReplyError.unsupportedTarget
        }

        return try store.append(
            AgentMessageDraft(
                senderName: senderName,
                senderSurfaceId: nil,
                senderWorkspaceId: nil,
                recipientSurfaceId: recipient.surfaceId,
                recipientWorkspaceId: recipient.workspaceId,
                body: body,
                threadId: nil,
                inReplyTo: recipient.replyTo
            )
        )
    }
}

struct AgentInboxItem: Identifiable, Equatable, Sendable {
    let id: String
    let kind: AgentInboxItemKind
    let createdAt: Date
    let workspaceId: String?
    let workspaceTitle: String
    let agentName: String
    let state: AgentMessageDeliveryState?
    var isUnread: Bool
    let title: String
    let preview: String
    let promptText: String?
    let agentText: String?
    let questionOptions: [WorkstreamQuestionOption]
    let permissionModes: [WorkstreamPermissionMode]
    let planModes: [WorkstreamExitPlanMode]
    let replyTarget: AgentInboxReplyTarget?
    let workstreamId: String?
    let searchText: String
}

enum AgentInboxProjection {
    static func project(
        messages: [AgentMessage],
        workstreamItems: [WorkstreamItem],
        workspaceTitles: [String: String],
        agentNamesBySurfaceId: [String: String] = [:],
        workstreamWorkspaceIds: [String: String] = [:],
        now: Date = Date()
    ) -> [AgentInboxItem] {
        var projected = messages.map {
            project(
                message: $0,
                workspaceTitles: workspaceTitles,
                agentNamesBySurfaceId: agentNamesBySurfaceId
            )
        }
        projected.append(contentsOf: projectWorkstreamItems(
            workstreamItems,
            workspaceTitles: workspaceTitles,
            workstreamWorkspaceIds: workstreamWorkspaceIds
        ))
        return projected.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
    }

    static func uniqueWorkstreamIDs(from items: [WorkstreamItem]) -> [String] {
        var seen = Set<String>()
        return items.compactMap { item in
            seen.insert(item.workstreamId).inserted ? item.workstreamId : nil
        }
    }

    static func filtered(_ items: [AgentInboxItem], query: String) -> [AgentInboxItem] {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased() }
        guard !tokens.isEmpty else { return items }
        return items.filter { item in
            tokens.allSatisfy { item.searchText.localizedCaseInsensitiveContains($0) }
        }
    }

    private static func project(
        message: AgentMessage,
        workspaceTitles: [String: String],
        agentNamesBySurfaceId: [String: String]
    ) -> AgentInboxItem {
        let isIncoming = message.senderSurfaceId != nil
        let agentName = isIncoming
            ? message.senderName
            : (agentNamesBySurfaceId[message.recipientSurfaceId] ?? message.senderName)
        let workspaceId = isIncoming ? message.senderWorkspaceId : message.recipientWorkspaceId
        let workspaceTitle = workspaceId.flatMap { workspaceTitles[$0] } ?? ""
        let replyTarget = message.senderSurfaceId.map {
            AgentInboxReplyTarget.agentMessage(
                surfaceId: $0,
                workspaceId: message.senderWorkspaceId,
                replyTo: message.id
            )
        }
        let title = message.senderName
        let searchText = [title, agentName, workspaceTitle, message.body]
            .joined(separator: " ")
        return AgentInboxItem(
            id: "message:\(message.id)",
            kind: .agentMessage,
            createdAt: message.createdAt,
            workspaceId: workspaceId,
            workspaceTitle: workspaceTitle,
            agentName: agentName,
            state: message.state,
            isUnread: message.state != .read,
            title: title,
            preview: message.body,
            promptText: nil,
            agentText: message.body,
            questionOptions: [],
            permissionModes: [],
            planModes: [],
            replyTarget: replyTarget,
            workstreamId: nil,
            searchText: searchText
        )
    }

    private static func projectWorkstreamItems(
        _ items: [WorkstreamItem],
        workspaceTitles: [String: String],
        workstreamWorkspaceIds: [String: String]
    ) -> [AgentInboxItem] {
        let grouped = Dictionary(grouping: items, by: \.workstreamId)
        var projected: [AgentInboxItem] = []
        for item in items where item.kind.isActionable && item.status.isPending {
            projected.append(projectPending(
                item,
                workspaceTitles: workspaceTitles,
                workstreamWorkspaceIds: workstreamWorkspaceIds
            ))
        }
        for item in items where item.kind == .stop {
            let related = grouped[item.workstreamId, default: []]
            let assistantText = related.reversed().compactMap { relatedItem -> String? in
                guard case .assistantMessage(let text) = relatedItem.payload else { return nil }
                return text
            }.first
            let promptText = item.context?.lastUserMessage ?? related.reversed().compactMap { relatedItem -> String? in
                guard case .userPrompt(let text) = relatedItem.payload else { return nil }
                return text
            }.first
            projected.append(projectFinishedTurn(
                item,
                assistantText: assistantText,
                promptText: promptText,
                workspaceTitles: workspaceTitles,
                workstreamWorkspaceIds: workstreamWorkspaceIds
            ))
        }
        return projected
    }

    private static func projectPending(
        _ item: WorkstreamItem,
        workspaceTitles: [String: String],
        workstreamWorkspaceIds: [String: String]
    ) -> AgentInboxItem {
        let workspaceId = workstreamWorkspaceIds[item.workstreamId]
        let workspaceTitle = workspaceId.flatMap { workspaceTitles[$0] } ?? item.cwd ?? ""
        let agentName = item.sourceID ?? item.source.rawValue
        let title: String
        let preview: String
        let questionOptions: [WorkstreamQuestionOption]
        let permissionModes: [WorkstreamPermissionMode]
        let planModes: [WorkstreamExitPlanMode]
        switch item.payload {
        case .permissionRequest(_, let toolName, _, _):
            title = toolName
            preview = toolName
            questionOptions = []
            permissionModes = WorkstreamPermissionMode.allCases
            planModes = []
        case .exitPlan(_, let plan, _):
            title = String(localized: "agentInbox.plan.title", defaultValue: "Plan approval")
            preview = WorkstreamExitPlanPreview(rawPlan: plan).planText
            questionOptions = []
            permissionModes = []
            planModes = WorkstreamExitPlanMode.allCases
        case .question(_, let questions):
            title = questions.first?.prompt ?? String(localized: "agentInbox.question.title", defaultValue: "Choose an answer")
            preview = questions.map(\.prompt).joined(separator: "\n")
            questionOptions = questions.first?.options ?? []
            permissionModes = []
            planModes = []
        default:
            title = item.title ?? ""
            preview = item.title ?? ""
            questionOptions = []
            permissionModes = []
            planModes = []
        }
        let searchText = [title, preview, agentName, workspaceTitle]
            .joined(separator: " ")
        return AgentInboxItem(
            id: "feed:\(item.id.uuidString)",
            kind: kind(for: item.kind),
            createdAt: item.createdAt,
            workspaceId: workspaceId,
            workspaceTitle: workspaceTitle,
            agentName: agentName,
            state: nil,
            isUnread: true,
            title: title,
            preview: preview,
            promptText: item.context?.lastUserMessage,
            agentText: preview,
            questionOptions: questionOptions,
            permissionModes: permissionModes,
            planModes: planModes,
            replyTarget: .feed(item.id),
            workstreamId: item.workstreamId,
            searchText: searchText
        )
    }

    private static func projectFinishedTurn(
        _ item: WorkstreamItem,
        assistantText: String?,
        promptText: String?,
        workspaceTitles: [String: String],
        workstreamWorkspaceIds: [String: String]
    ) -> AgentInboxItem {
        let workspaceId = workstreamWorkspaceIds[item.workstreamId]
        let workspaceTitle = workspaceId.flatMap { workspaceTitles[$0] } ?? item.cwd ?? ""
        let agentName = item.sourceID ?? item.source.rawValue
        let text = assistantText ?? item.title ?? ""
        let searchText = [text, promptText ?? "", agentName, workspaceTitle]
            .joined(separator: " ")
        return AgentInboxItem(
            id: "stop:\(item.id.uuidString)",
            kind: .finishedTurn,
            createdAt: item.createdAt,
            workspaceId: workspaceId,
            workspaceTitle: workspaceTitle,
            agentName: agentName,
            state: nil,
            isUnread: true,
            title: agentName,
            preview: text,
            promptText: promptText,
            agentText: text,
            questionOptions: [],
            permissionModes: [],
            planModes: [],
            replyTarget: .workstream(item.workstreamId),
            workstreamId: item.workstreamId,
            searchText: searchText
        )
    }

    private static func kind(for workstreamKind: WorkstreamKind) -> AgentInboxItemKind {
        switch workstreamKind {
        case .permissionRequest: return .permissionRequest
        case .exitPlan: return .planApproval
        case .question: return .question
        default: return .finishedTurn
        }
    }
}
