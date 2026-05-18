import Foundation

public nonisolated enum WorkstreamAgentNodeKind: String, Codable, Sendable, Equatable {
    case session
    case spawnRequest
}

public nonisolated enum WorkstreamAgentNodeStatus: String, Codable, Sendable, Equatable {
    case running
    case waiting
    case idle
    case done
    case unknown
}

public nonisolated struct WorkstreamAgentTreeNode: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let kind: WorkstreamAgentNodeKind
    public let workstreamId: String?
    public let focusWorkstreamId: String?
    public let source: WorkstreamSource?
    public let workspaceId: String?
    public let title: String
    public let model: String?
    public let subagentType: String?
    public let status: WorkstreamAgentNodeStatus
    public let taskDescription: String?
    public let childCount: Int
    public let children: [WorkstreamAgentTreeNode]

    public init(
        id: String,
        kind: WorkstreamAgentNodeKind,
        workstreamId: String?,
        focusWorkstreamId: String?,
        source: WorkstreamSource?,
        workspaceId: String?,
        title: String,
        model: String?,
        subagentType: String?,
        status: WorkstreamAgentNodeStatus,
        taskDescription: String?,
        childCount: Int,
        children: [WorkstreamAgentTreeNode]
    ) {
        self.id = id
        self.kind = kind
        self.workstreamId = workstreamId
        self.focusWorkstreamId = focusWorkstreamId
        self.source = source
        self.workspaceId = workspaceId
        self.title = title
        self.model = model
        self.subagentType = subagentType
        self.status = status
        self.taskDescription = taskDescription
        self.childCount = childCount
        self.children = children
    }
}

public nonisolated struct WorkstreamAgentGraphSnapshot: Codable, Sendable, Equatable {
    public let roots: [WorkstreamAgentTreeNode]
    public let nodeCount: Int
    public let edgeCount: Int
    public let maxDepth: Int

    public var isEmpty: Bool { roots.isEmpty }

    public static let empty = WorkstreamAgentGraphSnapshot(
        roots: [],
        nodeCount: 0,
        edgeCount: 0,
        maxDepth: 0
    )

    public init(
        roots: [WorkstreamAgentTreeNode],
        nodeCount: Int,
        edgeCount: Int,
        maxDepth: Int
    ) {
        self.roots = roots
        self.nodeCount = nodeCount
        self.edgeCount = edgeCount
        self.maxDepth = maxDepth
    }
}

public nonisolated enum WorkstreamAgentGraphBuilder {
    private static let sourcesByDescendingPrefixLength = WorkstreamSource.allCases
        .sorted(by: { $0.rawValue.count > $1.rawValue.count })

    public static func snapshot(from items: [WorkstreamItem]) -> WorkstreamAgentGraphSnapshot {
        func shouldCancel() -> Bool {
            Task.isCancelled
        }

        var records: [String: SessionRecord] = [:]
        var creationOrder: [String] = []
        var pendingSpawnsByParent: [String: [SpawnRecord]] = [:]

        func ensureRecord(
            workstreamId: String,
            source: WorkstreamSource,
            createdAt: Date,
            workspaceId: String? = nil
        ) {
            if records[workstreamId] == nil {
                records[workstreamId] = SessionRecord(
                    workstreamId: workstreamId,
                    source: source,
                    workspaceId: workspaceId,
                    createdAt: createdAt,
                    updatedAt: createdAt
                )
                creationOrder.append(workstreamId)
            } else if let workspaceId, records[workstreamId]?.workspaceId == nil {
                var record = records[workstreamId]
                record?.workspaceId = workspaceId
                records[workstreamId] = record
            }
        }

        func updateRecord(_ workstreamId: String, _ body: (inout SessionRecord) -> Void) {
            guard var record = records[workstreamId] else { return }
            body(&record)
            records[workstreamId] = record
        }

        func linkChildSession(
            childWorkstreamId: String,
            parentWorkstreamId: String,
            metadata: AgentGraphMetadata,
            childSource: WorkstreamSource,
            childWorkspaceId: String?
        ) {
            updateRecord(childWorkstreamId) { record in
                record.parentWorkstreamId = parentWorkstreamId
                record.mergeChild(metadata: metadata)
            }
            pruneResolvedSpawn(
                parentWorkstreamId: parentWorkstreamId,
                metadata: metadata,
                childSource: childSource,
                childWorkspaceId: childWorkspaceId
            )
        }

        func sourceFromWorkstreamId(_ workstreamId: String) -> WorkstreamSource? {
            for source in Self.sourcesByDescendingPrefixLength {
                if workstreamId.hasPrefix("\(source.rawValue)-") {
                    return source
                }
            }
            return nil
        }

        for item in items.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard !shouldCancel() else { return .empty }
            ensureRecord(
                workstreamId: item.workstreamId,
                source: item.source,
                createdAt: item.createdAt,
                workspaceId: item.workspaceId
            )
            let metadata = AgentGraphMetadata(item: item)
            updateRecord(item.workstreamId) { record in
                record.absorb(item, metadata: metadata)
            }

            if let parentWorkstreamId = metadata.parentWorkstreamId(source: item.source) {
                linkChildSession(
                    childWorkstreamId: item.workstreamId,
                    parentWorkstreamId: parentWorkstreamId,
                    metadata: metadata,
                    childSource: item.source,
                    childWorkspaceId: item.workspaceId
                )
            }

            if let childWorkstreamId = metadata.childWorkstreamId(source: item.source) {
                let childSource = metadata.childSource
                    ?? sourceFromWorkstreamId(childWorkstreamId)
                    ?? item.source
                ensureRecord(
                    workstreamId: childWorkstreamId,
                    source: childSource,
                    createdAt: item.createdAt,
                    workspaceId: nil
                )
                linkChildSession(
                    childWorkstreamId: childWorkstreamId,
                    parentWorkstreamId: item.workstreamId,
                    metadata: metadata,
                    childSource: childSource,
                    childWorkspaceId: nil
                )
            } else if let spawn = SpawnRecord(item: item, metadata: metadata),
                      !hasResolvedChild(parentWorkstreamId: item.workstreamId, spawn: spawn) {
                pendingSpawnsByParent[item.workstreamId, default: []].append(spawn)
            }
        }

        func pruneResolvedSpawn(
            parentWorkstreamId: String,
            metadata: AgentGraphMetadata,
            childSource: WorkstreamSource,
            childWorkspaceId: String?
        ) {
            guard var spawns = pendingSpawnsByParent[parentWorkstreamId],
                  !spawns.isEmpty else { return }
            guard let index = bestResolvedSpawnIndex(
                in: spawns,
                metadata: metadata,
                childSource: childSource,
                childWorkspaceId: childWorkspaceId
            ) else { return }
            spawns.remove(at: index)
            if spawns.isEmpty {
                pendingSpawnsByParent[parentWorkstreamId] = nil
            } else {
                pendingSpawnsByParent[parentWorkstreamId] = spawns
            }
        }

        func bestResolvedSpawnIndex(
            in spawns: [SpawnRecord],
            metadata: AgentGraphMetadata,
            childSource: WorkstreamSource,
            childWorkspaceId: String?
        ) -> Int? {
            var bestIndex: Int?
            var bestScore = 0
            var hasBestScoreTie = false
            for (index, spawn) in spawns.enumerated() {
                guard !shouldCancel() else { return nil }
                var score = 0
                if spawn.source == childSource {
                    score += SpawnResolutionScore.linkedChildSource
                }
                if let childWorkspaceId,
                   let workspaceId = spawn.workspaceId,
                   childWorkspaceId == workspaceId {
                    score += SpawnResolutionScore.linkedChildWorkspace
                }
                if let subagentType = metadata.childSubagentType,
                   let spawnSubagentType = spawn.subagentType,
                   subagentType == spawnSubagentType {
                    score += SpawnResolutionScore.subagentType
                }
                if let model = metadata.childModel,
                   let spawnModel = spawn.model,
                   model == spawnModel {
                    score += SpawnResolutionScore.model
                }
                if let taskDescription = metadata.childTaskDescription,
                   let spawnTaskDescription = spawn.taskDescription,
                   taskDescription == spawnTaskDescription {
                    score += SpawnResolutionScore.taskDescription
                }
                guard score > 0 else { continue }
                if score > bestScore {
                    bestIndex = index
                    bestScore = score
                    hasBestScoreTie = false
                } else if score == bestScore {
                    hasBestScoreTie = true
                }
            }
            return hasBestScoreTie ? nil : bestIndex
        }

        func hasResolvedChild(
            parentWorkstreamId: String,
            spawn: SpawnRecord
        ) -> Bool {
            var bestWorkstreamId: String?
            var bestScore = 0
            var hasBestScoreTie = false
            for record in records.values where record.parentWorkstreamId == parentWorkstreamId {
                guard !shouldCancel() else { return false }
                let score = spawn.resolutionScore(matching: record)
                guard score > 0 else { continue }
                if score > bestScore {
                    bestWorkstreamId = record.workstreamId
                    bestScore = score
                    hasBestScoreTie = false
                } else if score == bestScore {
                    hasBestScoreTie = true
                }
            }
            return bestWorkstreamId != nil && !hasBestScoreTie
        }

        var childrenByParent: [String: [String]] = [:]
        for record in records.values {
            guard !shouldCancel() else { return .empty }
            guard let parent = record.parentWorkstreamId,
                  records[parent] != nil,
                  parent != record.workstreamId
            else { continue }
            childrenByParent[parent, default: []].append(record.workstreamId)
        }

        for parent in childrenByParent.keys {
            childrenByParent[parent]?.sort { lhs, rhs in
                let l = records[lhs]?.updatedAt ?? .distantPast
                let r = records[rhs]?.updatedAt ?? .distantPast
                return l > r
            }
        }

        let childIds = Set(childrenByParent.values.flatMap { $0 })
        let roots = creationOrder
            .filter { !childIds.contains($0) }
            .sorted {
                let lhs = records[$0]?.updatedAt ?? .distantPast
                let rhs = records[$1]?.updatedAt ?? .distantPast
                return lhs > rhs
            }

        var visited: Set<String> = []
        var nodeCount = 0
        var edgeCount = 0
        var maxDepth = 0

        func makeNode(_ workstreamId: String, depth: Int) -> WorkstreamAgentTreeNode? {
            guard !shouldCancel() else { return nil }
            guard let record = records[workstreamId], visited.insert(workstreamId).inserted else {
                return nil
            }

            var children: [WorkstreamAgentTreeNode] = []
            for childId in childrenByParent[workstreamId] ?? [] {
                guard !shouldCancel() else { return nil }
                if let child = makeNode(childId, depth: depth + 1) {
                    children.append(child)
                    edgeCount += 1
                }
            }

            for spawn in pendingSpawnsByParent[workstreamId] ?? [] {
                children.append(spawn.node(parent: record))
                nodeCount += 1
                edgeCount += 1
                maxDepth = max(maxDepth, depth + 1)
            }

            nodeCount += 1
            maxDepth = max(maxDepth, depth)
            return record.node(children: children)
        }

        var treeRoots = roots.compactMap { makeNode($0, depth: 0) }
        for workstreamId in creationOrder where !visited.contains(workstreamId) {
            guard !shouldCancel() else { return .empty }
            if let fallbackRoot = makeNode(workstreamId, depth: 0) {
                treeRoots.append(fallbackRoot)
            }
        }

        return WorkstreamAgentGraphSnapshot(
            roots: treeRoots,
            nodeCount: nodeCount,
            edgeCount: edgeCount,
            maxDepth: maxDepth
        )
    }
}

private enum SpawnResolutionScore {
    static let linkedChildSource = 2
    static let linkedChildWorkspace = 2
    static let existingChildSource = 1
    static let existingChildWorkspace = 1
    static let subagentType = 4
    static let model = 3
    static let taskDescription = 4
}

private struct SessionRecord {
    let workstreamId: String
    let source: WorkstreamSource
    var workspaceId: String?
    var title: String?
    var model: String?
    var subagentType: String?
    var taskDescription: String?
    var parentWorkstreamId: String?
    var status: WorkstreamAgentNodeStatus = .unknown
    let createdAt: Date
    var updatedAt: Date

    mutating func absorb(_ item: WorkstreamItem, metadata: AgentGraphMetadata? = nil) {
        updatedAt = max(updatedAt, item.updatedAt)
        if workspaceId == nil {
            workspaceId = item.workspaceId
        }
        if let cwd = item.cwd, title == nil {
            title = Self.basename(cwd)
        }

        let resolvedMetadata = metadata ?? AgentGraphMetadata(item: item)
        mergeSession(metadata: resolvedMetadata)

        switch item.status {
        case .pending:
            status = .waiting
        case .resolved, .expired, .telemetry:
            updateStatus(from: item.payload)
        }

        switch item.payload {
        case .userPrompt(let text):
            mergeTaskDescription(text)
        default:
            break
        }

        if let context = item.context {
            mergeTaskDescription(context.lastUserMessage)
        }
    }

    mutating func mergeSession(metadata: AgentGraphMetadata) {
        if let model = metadata.sessionModel, !model.isEmpty {
            self.model = model
        }
        if let subagentType = metadata.sessionSubagentType, !subagentType.isEmpty {
            self.subagentType = subagentType
        }
        mergeTaskDescription(metadata.sessionTaskDescription)
        if let description = metadata.sessionDescription, !description.isEmpty, title == nil {
            title = description
        }
    }

    mutating func mergeChild(metadata: AgentGraphMetadata) {
        if let model = metadata.childModel, !model.isEmpty {
            self.model = model
        }
        if let subagentType = metadata.childSubagentType, !subagentType.isEmpty {
            self.subagentType = subagentType
        }
        mergeTaskDescription(metadata.childTaskDescription)
        if let description = metadata.childDescription, !description.isEmpty, title == nil {
            title = description
        }
    }

    func node(children: [WorkstreamAgentTreeNode]) -> WorkstreamAgentTreeNode {
        WorkstreamAgentTreeNode(
            id: "session:\(workstreamId)",
            kind: .session,
            workstreamId: workstreamId,
            focusWorkstreamId: workstreamId,
            source: source,
            workspaceId: workspaceId,
            title: title ?? source.rawValue,
            model: model,
            subagentType: subagentType,
            status: status,
            taskDescription: taskDescription,
            childCount: children.count,
            children: children
        )
    }

    private mutating func mergeTaskDescription(_ value: String?) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return }
        taskDescription = value
    }

    private mutating func updateStatus(from payload: WorkstreamPayload) {
        switch payload {
        case .sessionEnd:
            status = .done
        case .stop:
            if status != .done {
                status = .idle
            }
        case .sessionStart, .userPrompt, .toolUse, .toolResult, .todos, .assistantMessage:
            if status != .waiting && status != .done {
                status = .running
            }
        case .permissionRequest, .exitPlan, .question:
            if status != .waiting && status != .done {
                status = .running
            }
        }
    }

    private static func basename(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    static func isSpawnTool(_ toolName: String) -> Bool {
        WorkstreamAgentSpawnTool.isSpawnToolName(toolName)
    }
}

private struct SpawnRecord {
    let id: String
    let source: WorkstreamSource
    let workspaceId: String?
    let title: String
    let model: String?
    let subagentType: String?
    let taskDescription: String?
    let createdAt: Date

    init?(item: WorkstreamItem, metadata: AgentGraphMetadata) {
        guard case .toolUse(let toolName, _) = item.payload,
              SessionRecord.isSpawnTool(toolName)
        else { return nil }
        self.id = "spawn:\(item.id.uuidString)"
        self.source = item.source
        self.workspaceId = item.workspaceId
        self.title = metadata.childDescription
            ?? metadata.childSubagentType
            ?? String(toolName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        self.model = metadata.childModel
        self.subagentType = metadata.childSubagentType
        self.taskDescription = metadata.childTaskDescription
        self.createdAt = item.createdAt
    }

    func node(parent: SessionRecord) -> WorkstreamAgentTreeNode {
        WorkstreamAgentTreeNode(
            id: id,
            kind: .spawnRequest,
            workstreamId: nil,
            focusWorkstreamId: parent.workstreamId,
            source: source,
            workspaceId: workspaceId ?? parent.workspaceId,
            title: title,
            model: model,
            subagentType: subagentType,
            status: .waiting,
            taskDescription: taskDescription,
            childCount: 0,
            children: []
        )
    }

    func resolutionScore(matching record: SessionRecord) -> Int {
        var score = 0
        if source == record.source {
            score += SpawnResolutionScore.existingChildSource
        }
        if let workspaceId,
           let recordWorkspaceId = record.workspaceId,
           workspaceId == recordWorkspaceId {
            score += SpawnResolutionScore.existingChildWorkspace
        }
        if let subagentType,
           let recordSubagentType = record.subagentType,
           subagentType == recordSubagentType {
            score += SpawnResolutionScore.subagentType
        }
        if let model,
           let recordModel = record.model,
           model == recordModel {
            score += SpawnResolutionScore.model
        }
        if let taskDescription,
           let recordTaskDescription = record.taskDescription,
           taskDescription == recordTaskDescription {
            score += SpawnResolutionScore.taskDescription
        }
        return score
    }
}

private struct AgentGraphMetadata {
    let source: WorkstreamSource
    let extra: [String: Any]
    let toolInput: [String: Any]
    let isSpawnTool: Bool

    init(item: WorkstreamItem) {
        let toolName: String?
        let toolInputJSON: String?
        if case .toolUse(let name, let json) = item.payload {
            toolName = name
            toolInputJSON = json
        } else if case .permissionRequest(_, let name, let json, _) = item.payload {
            toolName = name
            toolInputJSON = json
        } else {
            toolName = nil
            toolInputJSON = nil
        }
        self.init(
            source: item.source,
            extraFieldsJSON: item.extraFieldsJSON,
            toolName: toolName,
            toolInputJSON: toolInputJSON
        )
    }

    init(
        source: WorkstreamSource,
        extraFieldsJSON: String?,
        toolName: String?,
        toolInputJSON: String?
    ) {
        self.source = source
        self.extra = Self.dictionary(from: extraFieldsJSON)
        let parsedToolInput = Self.dictionary(from: toolInputJSON)
        self.isSpawnTool = toolName.map(SessionRecord.isSpawnTool) ?? false
        if isSpawnTool {
            self.toolInput = parsedToolInput
        } else {
            self.toolInput = [:]
        }
    }

    var childSource: WorkstreamSource? {
        string(keys: ["child_source", "childSource", "subagent_source", "subagentSource"])
            .flatMap(WorkstreamSource.init(wireName:))
    }

    var parentSource: WorkstreamSource? {
        string(keys: ["parent_source", "parentSource", "parent_agent_source", "parentAgentSource"])
            .flatMap(WorkstreamSource.init(wireName:))
    }

    var sessionModel: String? {
        if isSpawnTool {
            return extraString(keys: ["model"])
        }
        return extraString(keys: ["model", "subagent_model", "subagentModel"])
    }

    var sessionSubagentType: String? {
        guard !isSpawnTool else { return nil }
        return extraString(keys: ["subagent_type", "subagentType", "agent_type", "agentType"])
    }

    var sessionDescription: String? {
        guard !isSpawnTool else { return nil }
        return extraString(keys: ["description", "title", "name"])
    }

    var sessionTaskDescription: String? {
        guard !isSpawnTool else { return nil }
        return extraString(keys: ["task_description", "taskDescription", "prompt", "message"])
    }

    var childModel: String? {
        toolInputString(keys: ["subagent_model", "subagentModel", "model"])
            ?? extraString(keys: ["subagent_model", "subagentModel", "model"])
    }

    var childSubagentType: String? {
        toolInputString(keys: ["subagent_type", "subagentType", "agent_type", "agentType"])
            ?? extraString(keys: ["subagent_type", "subagentType", "agent_type", "agentType"])
    }

    var childDescription: String? {
        toolInputString(keys: ["description", "title", "name"])
            ?? extraString(keys: ["description", "title", "name"])
    }

    var childTaskDescription: String? {
        toolInputString(keys: ["task_description", "taskDescription", "prompt", "message"])
            ?? extraString(keys: ["task_description", "taskDescription", "prompt", "message"])
    }

    func parentWorkstreamId(source: WorkstreamSource) -> String? {
        if let value = string(keys: ["parent_workstream_id", "parentWorkstreamId", "parent_workstream", "parentWorkstream"]) {
            return value
        }
        if let sessionId = string(keys: ["parent_session_id", "parentSessionId", "parentSessionID"]) {
            return "\((parentSource ?? source).rawValue)-\(sessionId)"
        }
        return nil
    }

    func childWorkstreamId(source: WorkstreamSource) -> String? {
        if let value = string(keys: ["child_workstream_id", "childWorkstreamId", "subagent_workstream_id", "subagentWorkstreamId"]) {
            return value
        }
        if let sessionId = string(keys: ["child_session_id", "childSessionId", "childSessionID", "subagent_session_id", "subagentSessionId"]) {
            return "\((childSource ?? source).rawValue)-\(sessionId)"
        }
        return nil
    }

    private func string(keys: [String]) -> String? {
        for key in keys {
            if let value = normalizedString(extra[key]) {
                return value
            }
            if let value = normalizedString(toolInput[key]) {
                return value
            }
        }
        return nil
    }

    private func extraString(keys: [String]) -> String? {
        for key in keys {
            if let value = normalizedString(extra[key]) {
                return value
            }
        }
        return nil
    }

    private func toolInputString(keys: [String]) -> String? {
        for key in keys {
            if let value = normalizedString(toolInput[key]) {
                return value
            }
        }
        return nil
    }

    private static func dictionary(from json: String?) -> [String: Any] {
        guard let json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let dict = object as? [String: Any]
        else { return [:] }
        return dict
    }

    private func normalizedString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}
