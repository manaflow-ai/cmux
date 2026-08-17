import Foundation
import CmuxSidebar

@MainActor
struct SidebarSessionRowSnapshot: Equatable, Identifiable {
    let id: UUID
    let status: SessionCardSnapshot.Status
    let groupID: String

    init(id: UUID, status: SessionCardSnapshot.Status, groupID: String) {
        self.id = id
        self.status = status
        self.groupID = groupID
    }

    init(workspace: Workspace, status: SessionCardSnapshot.Status, groups: [SessionCardGroup] = []) {
        id = workspace.id
        self.status = status
        groupID = SessionCardGroup.resolveID(
            status: status,
            isPinned: workspace.isPinned,
            configured: groups
        )
    }
}

struct SessionCardSnapshot: Equatable {
    enum Host: Equatable {
        case laptop
        case devbox

        var displayName: String {
            switch self {
            case .laptop:
                return String(localized: "sidebar.sessionCard.host.laptop", defaultValue: "laptop")
            case .devbox:
                return String(localized: "sidebar.sessionCard.host.devbox", defaultValue: "devbox")
            }
        }
    }

    enum Badge: Equatable {
        case indexedWorktree(Int)
        case unindexedHost(Host)
    }

    enum Mode: Equatable {
        case plan
        case defaultMode
        case edit

        init(metadataValue: String?) {
            let normalized = metadataValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
                ?? ""
            if normalized.contains("plan") {
                self = .plan
            } else if normalized.contains("edit") {
                self = .edit
            } else {
                self = .defaultMode
            }
        }

        var displayName: String {
            switch self {
            case .plan:
                return String(localized: "sidebar.sessionCard.mode.plan", defaultValue: "Plan")
            case .defaultMode:
                return String(localized: "sidebar.sessionCard.mode.default", defaultValue: "Default")
            case .edit:
                return String(localized: "sidebar.sessionCard.mode.edit", defaultValue: "Edit")
            }
        }
    }

    enum Status: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
        case ready
        case needsInput
        case working
        case babysitting
        case done
        case exited

        init?(metadataValue: String?) {
            let normalized = metadataValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
                ?? ""
            switch normalized {
            case "connected", "online", "ready", "idle", "review-ready", "ready-for-review":
                self = .ready
            case "running", "working", "busy", "in-progress", "processing":
                self = .working
            case "babysitting", "babysit", "pr-babysitting":
                self = .babysitting
            case "waiting", "needs-input", "needsinput", "blocked", "paused":
                self = .needsInput
            case "done", "completed", "complete", "finished", "success", "succeeded":
                self = .done
            case "exited", "disconnected", "offline", "failed", "error":
                self = .exited
            default:
                return nil
            }
        }

        init?(sidebarEntry: SidebarStatusEntry) {
            switch sidebarEntry.icon {
            case "bolt.fill":
                self = .working
            case "figure.child":
                self = .babysitting
            case "bell.fill", "exclamationmark.circle", "exclamationmark.triangle.fill":
                self = .needsInput
            case "pause.circle.fill", "checkmark.circle", "checkmark.circle.fill":
                self = .ready
            case "xmark.circle", "xmark.circle.fill":
                self = .exited
            default:
                self.init(metadataValue: sidebarEntry.value)
            }
        }

        var displayName: String {
            switch self {
            case .ready:
                return String(localized: "sidebar.sessionCard.status.ready", defaultValue: "Ready")
            case .needsInput:
                return String(localized: "sidebar.sessionCard.status.needsInput", defaultValue: "Needs input")
            case .working:
                return String(localized: "sidebar.sessionCard.status.working", defaultValue: "Working")
            case .babysitting:
                return String(localized: "sidebar.sessionCard.status.babysitting", defaultValue: "Babysitting")
            case .done:
                return String(localized: "sidebar.sessionCard.status.done", defaultValue: "Done")
            case .exited:
                return String(localized: "sidebar.sessionCard.status.exited", defaultValue: "Exited")
            }
        }

        var iconName: String? {
            switch self {
            case .ready:
                return "checkmark.circle"
            case .needsInput:
                return "exclamationmark.circle"
            case .working:
                return "bolt.fill"
            case .babysitting:
                return "figure.child"
            case .done:
                return "checkmark"
            case .exited:
                return nil
            }
        }

        var colorHex: String {
            switch self {
            case .ready:
                return "#3FB950"
            case .needsInput:
                return "#E3B341"
            case .working:
                return "#58A6FF"
            case .babysitting:
                return "#E67E22"
            case .done:
                return "#8A8A95"
            case .exited:
                return "#6E6E78"
            }
        }

        @MainActor
        static func resolve(workspace: Workspace) -> Status {
            let lifecycleStates = workspace.agentLifecycleStatesByPanelId.values.flatMap { $0.values }
            let metadataStatus = recognizedMetadataStatus(in: workspace)

            if metadataStatus == .babysitting {
                return .babysitting
            }
            if lifecycleStates.contains(.running) ||
                metadataStatus == .working ||
                workspace.remoteConnectionState == .connecting ||
                workspace.remoteConnectionState == .reconnecting {
                return .working
            }
            if lifecycleStates.contains(.needsInput) || metadataStatus == .needsInput {
                return .needsInput
            }
            if workspace.isRemoteWorkspace,
               !workspace.hasActiveRemoteTerminalSessions,
               (workspace.remoteConnectionState == .disconnected || workspace.remoteConnectionState == .error) {
                return .exited
            }
            if metadataStatus == .ready {
                return .ready
            }
            if metadataStatus == .exited {
                return .exited
            }
            if lifecycleStates.contains(.idle) ||
                !workspace.agentPIDPanelIdsByKey.isEmpty ||
                !workspace.restoredAgentSnapshotsByPanelId.isEmpty ||
                workspace.hasActiveRemoteTerminalSessions {
                return .ready
            }
            return .done
        }

        @MainActor
        private static func recognizedMetadataStatus(in workspace: Workspace) -> Status? {
            let preferredKeys = Set([
                "session.status", "agent.status", "status",
                "workflow", "agent", "wk", "session",
            ])
                .union(AgentHibernationLifecycleStatusKeys.allowedStatusKeys)
            return workspace.sidebarStatusEntriesVisibleForDisplay()
                .filter { preferredKeys.contains($0.key) }
                .sorted { lhs, rhs in
                    if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                    return lhs.timestamp > rhs.timestamp
                }
                .compactMap(Status.init(sidebarEntry:))
                .first
        }
    }

    struct Diff: Equatable {
        let added: Int
        let deleted: Int

        init(added: Int, deleted: Int) {
            self.added = max(0, abs(added))
            self.deleted = max(0, abs(deleted))
        }

        var isEmpty: Bool {
            added == 0 && deleted == 0
        }

        static func parseCount(_ value: String?) -> Int {
            guard let value else { return 0 }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return 0 }
            if let parsed = Int(trimmed) {
                return abs(parsed)
            }
            let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            return abs(Int(stripped) ?? 0)
        }
    }

    let workspaceNumber: Int
    let badge: Badge
    let name: String
    let colorHex: String
    let host: Host
    let branchName: String?
    let modelName: String?
    let mode: Mode
    let status: Status
    let isPinned: Bool
    let diff: Diff

    init(
        workspaceNumber: Int,
        name: String,
        colorHex: String,
        host: Host,
        branchName: String?,
        modelName: String?,
        mode: Mode,
        status: Status,
        isPinned: Bool = false,
        diff: Diff,
        badge: Badge? = nil
    ) {
        self.workspaceNumber = min(10, max(1, workspaceNumber))
        self.badge = badge ?? .indexedWorktree(self.workspaceNumber)
        self.name = Self.nonEmpty(name) ?? String(localized: "sidebar.sessionCard.defaultName", defaultValue: "Workspace")
        self.colorHex = colorHex
        self.host = host
        self.branchName = Self.nonEmpty(branchName)
        self.modelName = Self.nonEmpty(modelName)
        self.mode = mode
        self.status = status
        self.isPinned = isPinned
        self.diff = diff
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func indexedWorktreeNumber(in rawValue: String) -> Int? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let lowercased = value.lowercased()
        if lowercased.hasPrefix("[wk"),
           let closingBracket = lowercased.firstIndex(of: "]") {
            let slotText = lowercased[..<closingBracket].dropFirst(3)
            if let slot = Int(slotText) {
                return slot
            }
        }
        if let slot = leadingKeycapWorktreeNumber(in: lowercased) {
            return slot
        }

        let normalizedPath = lowercased
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "~", with: "/")
        for component in normalizedPath.split(separator: "/", omittingEmptySubsequences: true) {
            if let slot = indexedWorktreeNumber(inPathComponent: component, prefix: "ws-wk") {
                return slot
            }
            if let slot = indexedWorktreeNumber(inPathComponent: component, prefix: "wk") {
                return slot
            }
            if let marker = component.range(of: "-wk", options: .backwards),
               let slot = Int(component[marker.upperBound...]) {
                return slot
            }
        }
        return nil
    }

    private static func leadingKeycapWorktreeNumber(in value: String) -> Int? {
        let scalars = Array(value.unicodeScalars)
        guard let first = scalars.first,
              let slot = Int(String(first)),
              slot >= 0
        else {
            return nil
        }

        var index = 1
        if index < scalars.count, scalars[index].value == 0xFE0F {
            index += 1
        }
        guard index < scalars.count, scalars[index].value == 0x20E3 else {
            return nil
        }
        return slot
    }

    private static func indexedWorktreeNumber(
        inPathComponent component: Substring,
        prefix: String
    ) -> Int? {
        guard component.hasPrefix(prefix) else { return nil }
        let slotText = component.dropFirst(prefix.count)
        let digits = slotText.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }

        let remainder = slotText.dropFirst(digits.count)
        guard remainder.isEmpty || String(remainder) == ".sh" else { return nil }
        return Int(digits)
    }
}
