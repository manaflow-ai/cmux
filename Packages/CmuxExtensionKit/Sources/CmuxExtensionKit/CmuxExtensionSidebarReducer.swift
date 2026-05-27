import Foundation

public enum CmuxExtensionSidebarEvent: Codable, Equatable, Sendable {
    case snapshotReplaced(CmuxExtensionSidebarSnapshot)
    case workspaceUpserted(CmuxExtensionWorkspaceSnapshot)
    case workspaceRemoved(UUID)
    case workspacesReordered([UUID])
    case workspaceSelected(UUID?)
}

public struct CmuxExtensionSidebarReducer {
    public static func requiresSnapshotReplacement(after frame: CmuxExtensionEventFrame) -> Bool {
        switch frame.name {
        case "notification.created":
            return redactedFields(from: frame.payload).contains { field in
                field == "title" || field == "subtitle" || field == "body"
            }

        case "workspace.created", "workspace.moved":
            return true

        case "notification.read", "notification.cleared", "notification.removed":
            return true

        case "workspace.action":
            return true

        default:
            return frame.name.hasPrefix("sidebar.")
        }
    }

    public static func reduce(
        _ snapshot: CmuxExtensionSidebarSnapshot,
        event: CmuxExtensionSidebarEvent
    ) -> CmuxExtensionSidebarSnapshot {
        switch event {
        case .snapshotReplaced(let replacement):
            return replacement

        case .workspaceUpserted(let workspace):
            var workspaces = snapshot.workspaces
            if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
                workspaces[index] = workspace
            } else {
                workspaces.append(workspace)
            }
            return CmuxExtensionSidebarSnapshot(
                sequence: snapshot.sequence + 1,
                selectedWorkspaceId: snapshot.selectedWorkspaceId,
                workspaces: workspaces,
                windowId: snapshot.windowId
            )

        case .workspaceRemoved(let id):
            let workspaces = snapshot.workspaces.filter { $0.id != id }
            return CmuxExtensionSidebarSnapshot(
                sequence: snapshot.sequence + 1,
                selectedWorkspaceId: snapshot.selectedWorkspaceId == id ? nil : snapshot.selectedWorkspaceId,
                workspaces: workspaces,
                windowId: snapshot.windowId
            )

        case .workspacesReordered(let ids):
            var orderedIds: [UUID] = []
            var seenIds: Set<UUID> = []
            for id in ids where seenIds.insert(id).inserted {
                orderedIds.append(id)
            }
            let workspacesById = Dictionary(
                snapshot.workspaces.map { ($0.id, $0) },
                uniquingKeysWith: { _, replacement in replacement }
            )
            let orderedSet = Set(orderedIds)
            var known = orderedIds.compactMap { workspacesById[$0] }
            known.append(contentsOf: snapshot.workspaces.filter { !orderedSet.contains($0.id) })
            return CmuxExtensionSidebarSnapshot(
                sequence: snapshot.sequence + 1,
                selectedWorkspaceId: snapshot.selectedWorkspaceId,
                workspaces: known,
                windowId: snapshot.windowId
            )

        case .workspaceSelected(let id):
            return CmuxExtensionSidebarSnapshot(
                sequence: snapshot.sequence + 1,
                selectedWorkspaceId: id,
                workspaces: snapshot.workspaces,
                windowId: snapshot.windowId
            )
        }
    }

    public static func reduce(
        _ snapshot: CmuxExtensionSidebarSnapshot,
        event frame: CmuxExtensionEventFrame
    ) -> CmuxExtensionSidebarSnapshot {
        guard frame.sequence > snapshot.sequence else { return snapshot }
        var next = snapshot
        next.sequence = frame.sequence

        switch frame.name {
        case "workspace.created":
            guard let workspaceId = resolvedWorkspaceId(frame),
                  !next.workspaces.contains(where: { $0.id == workspaceId }) else {
                return next
            }
            let title = frame.payload["title"]?.stringValue
                ?? frame.payload["custom_title"]?.stringValue
                ?? "Workspace"
            let workspace = CmuxExtensionWorkspaceSnapshot(
                id: workspaceId,
                title: title,
                customDescription: nil,
                isPinned: false,
                rootPath: frame.payload["cwd"]?.stringValue ?? frame.payload["root_path"]?.stringValue,
                projectRootPath: frame.payload["project_root_path"]?.stringValue,
                branchSummary: nil,
                remoteDisplayTarget: nil,
                remoteConnectionState: nil,
                unreadCount: 0,
                latestNotificationText: nil,
                listeningPorts: []
            )
            let insertionIndex = min(max(frame.payload["index"]?.intValue ?? next.workspaces.count, 0), next.workspaces.count)
            next.workspaces.insert(workspace, at: insertionIndex)
            if frame.payload["selected"]?.boolValue == true {
                next.selectedWorkspaceId = workspaceId
            }

        case "workspace.closed":
            guard let workspaceId = resolvedWorkspaceId(frame) else { return next }
            next.workspaces.removeAll { $0.id == workspaceId }
            if next.selectedWorkspaceId == workspaceId {
                next.selectedWorkspaceId = nil
            }

        case "workspace.selected":
            if let workspaceId = resolvedWorkspaceId(frame) {
                guard next.workspaces.contains(where: { $0.id == workspaceId }) else {
                    return next
                }
                next.selectedWorkspaceId = workspaceId
            } else {
                next.selectedWorkspaceId = nil
            }

        case "workspace.renamed":
            guard let workspaceId = resolvedWorkspaceId(frame),
                  let index = next.workspaces.firstIndex(where: { $0.id == workspaceId }),
                  let title = renamedWorkspaceTitle(from: frame.payload) else {
                return next
            }
            next.workspaces[index].title = title

        case "workspace.reordered":
            let pinnedIds = reorderedPinnedWorkspaceIds(from: frame.payload)
            var didApplyLocalReorder = false
            if let order = reorderedWorkspaceIds(from: frame.payload) {
                var orderedIds: [UUID] = []
                var seenIds: Set<UUID> = []
                for id in order where seenIds.insert(id).inserted {
                    orderedIds.append(id)
                }
                let workspacesById = Dictionary(
                    next.workspaces.map { ($0.id, $0) },
                    uniquingKeysWith: { _, replacement in replacement }
                )
                let orderedSet = Set(orderedIds)
                var known: [CmuxExtensionWorkspaceSnapshot] = []
                for id in orderedIds {
                    guard let workspace = workspacesById[id] else { continue }
                    didApplyLocalReorder = true
                    known.append(workspace)
                }
                known.append(contentsOf: next.workspaces.filter { !orderedSet.contains($0.id) })
                next.workspaces = known
            } else if let workspaceId = resolvedWorkspaceId(frame),
                      let index = reorderedWorkspaceIndex(from: frame.payload),
                      let workspaces = movingWorkspace(next.workspaces, workspaceId: workspaceId, toIndex: index) {
                next.workspaces = workspaces
                didApplyLocalReorder = true
            }
            if let pinnedIds, didApplyLocalReorder {
                let pinnedSet = Set(pinnedIds)
                for index in next.workspaces.indices {
                    next.workspaces[index].isPinned = pinnedSet.contains(next.workspaces[index].id)
                }
            }

        case "workspace.prompt.submitted":
            guard let workspaceId = resolvedWorkspaceId(frame),
                  let index = next.workspaces.firstIndex(where: { $0.id == workspaceId }) else {
                return next
            }
            let message = frame.payload["message_preview"]?.stringValue
                ?? frame.payload["prompt"]?.stringValue
                ?? frame.payload["message"]?.stringValue
            guard let prompt = normalizedPrompt(message) else { return next }
            next.workspaces[index].latestSubmittedMessage = prompt
            next.workspaces[index].latestSubmittedAt = frame.occurredAt

        case "notification.created":
            guard let workspaceId = resolvedWorkspaceId(frame),
                  let index = next.workspaces.firstIndex(where: { $0.id == workspaceId }) else {
                return next
            }
            let isRead = frame.payload["is_read"]?.boolValue ?? false
            if !isRead {
                next.workspaces[index].unreadCount += 1
            }
            next.workspaces[index].latestNotificationText = notificationText(from: frame.payload)

        case "notification.read", "notification.cleared":
            guard let workspaceId = resolvedWorkspaceId(frame),
                  let index = next.workspaces.firstIndex(where: { $0.id == workspaceId }) else {
                return next
            }
            let nextUnreadCount = max(0, next.workspaces[index].unreadCount - notificationCount(from: frame.payload))
            next.workspaces[index].unreadCount = nextUnreadCount
            if nextUnreadCount == 0 {
                next.workspaces[index].latestNotificationText = nil
            }

        case "notification.removed":
            guard let workspaceId = resolvedWorkspaceId(frame),
                  let index = next.workspaces.firstIndex(where: { $0.id == workspaceId }) else {
                return next
            }
            let wasRead = frame.payload["is_read"]?.boolValue ?? false
            if !wasRead {
                next.workspaces[index].unreadCount = max(0, next.workspaces[index].unreadCount - 1)
            }
            if next.workspaces[index].unreadCount == 0
                || notificationText(from: frame.payload) == next.workspaces[index].latestNotificationText {
                next.workspaces[index].latestNotificationText = nil
            }

        default:
            break
        }

        return next
    }

    private static func resolvedWorkspaceId(_ frame: CmuxExtensionEventFrame) -> UUID? {
        frame.workspaceId
            ?? frame.payload["workspace_id"]?.uuidValue
            ?? frame.payload["id"]?.uuidValue
    }

    private static func normalizedPrompt(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func reorderedWorkspaceIds(from payload: [String: CmuxExtensionJSONValue]) -> [UUID]? {
        if let ids = payload["workspace_ids"]?.uuidArrayValue
            ?? payload["order"]?.uuidArrayValue
            ?? payload["ids"]?.uuidArrayValue {
            return ids
        }
        if let result = payload["result"]?.objectValue,
           let ids = reorderedWorkspaceIds(from: result) {
            return ids
        }
        if let params = payload["params"]?.objectValue,
           let ids = reorderedWorkspaceIds(from: params) {
            return ids
        }
        return nil
    }

    private static func reorderedPinnedWorkspaceIds(from payload: [String: CmuxExtensionJSONValue]) -> [UUID]? {
        if let ids = payload["pinned_workspace_ids"]?.uuidArrayValue
            ?? payload["pinned_ids"]?.uuidArrayValue {
            return ids
        }
        if let result = payload["result"]?.objectValue,
           let ids = reorderedPinnedWorkspaceIds(from: result) {
            return ids
        }
        if let params = payload["params"]?.objectValue,
           let ids = reorderedPinnedWorkspaceIds(from: params) {
            return ids
        }
        return nil
    }

    private static func reorderedWorkspaceIndex(from payload: [String: CmuxExtensionJSONValue]) -> Int? {
        if let index = payload["index"]?.intValue {
            return index
        }
        if let result = payload["result"]?.objectValue,
           let index = reorderedWorkspaceIndex(from: result) {
            return index
        }
        if let params = payload["params"]?.objectValue,
           let index = reorderedWorkspaceIndex(from: params) {
            return index
        }
        return nil
    }

    private static func movingWorkspace(
        _ workspaces: [CmuxExtensionWorkspaceSnapshot],
        workspaceId: UUID,
        toIndex index: Int
    ) -> [CmuxExtensionWorkspaceSnapshot]? {
        var next = workspaces
        guard let sourceIndex = next.firstIndex(where: { $0.id == workspaceId }) else { return nil }
        let workspace = next.remove(at: sourceIndex)
        let insertionIndex = min(max(index, 0), next.count)
        next.insert(workspace, at: insertionIndex)
        return next
    }

    private static func renamedWorkspaceTitle(from payload: [String: CmuxExtensionJSONValue]) -> String? {
        if let title = payload["title"]?.stringValue {
            return title
        }
        if let title = payload["custom_title"]?.stringValue {
            return title
        }

        let result = payload["result"]?.objectValue
        if let title = result?["title"]?.stringValue {
            return title
        }
        if let title = result?["custom_title"]?.stringValue {
            return title
        }

        let params = payload["params"]?.objectValue
        if let title = params?["title"]?.stringValue {
            return title
        }
        return params?["custom_title"]?.stringValue
    }

    private static func notificationText(from payload: [String: CmuxExtensionJSONValue]) -> String? {
        normalizedPrompt(payload["body"]?.stringValue)
            ?? normalizedPrompt(payload["title"]?.stringValue)
            ?? normalizedPrompt(payload["subtitle"]?.stringValue)
    }

    private static func notificationCount(from payload: [String: CmuxExtensionJSONValue]) -> Int {
        if let count = payload["count"]?.intValue {
            return max(0, count)
        }
        if let ids = payload["notification_ids"]?.arrayValue {
            return ids.count
        }
        return 1
    }

    private static func redactedFields(from payload: [String: CmuxExtensionJSONValue]) -> Set<String> {
        Set(payload["redacted_fields"]?.stringArrayValue ?? [])
    }
}

private extension CmuxExtensionJSONValue {
    var objectValue: [String: CmuxExtensionJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [CmuxExtensionJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringArrayValue: [String]? {
        guard let values = arrayValue else { return nil }
        let strings = values.compactMap(\.stringValue)
        return strings.count == values.count ? strings : nil
    }

    var uuidValue: UUID? {
        stringValue.flatMap(UUID.init(uuidString:))
    }

    var uuidArrayValue: [UUID]? {
        guard let values = arrayValue else { return nil }
        let ids = values.compactMap(\.uuidValue)
        return ids.count == values.count ? ids : nil
    }
}
