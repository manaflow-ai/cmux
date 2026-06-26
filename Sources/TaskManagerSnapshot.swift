import Foundation

struct CmuxTaskManagerSnapshot {
    static let empty = CmuxTaskManagerSnapshot(
        rows: [],
        agentRows: [],
        aggregateRows: [],
        childMemoryRows: [],
        total: .zero,
        sampledAt: nil,
        memoryDiagnostic: nil
    )

    /// Pure name->asset classifier seam used by the parse helpers below to map a
    /// row's free-form name candidates to a brand-mark asset name.
    private static let agentAssetResolver = SessionAgentAssetResolver.standard

    let rows: [CmuxTaskManagerRow]
    let agentRows: [CmuxTaskManagerRow]
    let aggregateRows: [CmuxTaskManagerRow]
    let childMemoryRows: [CmuxTaskManagerRow]
    let total: CmuxTaskManagerResources
    let sampledAt: Date?
    let memoryDiagnostic: CmuxTaskManagerMemoryDiagnostic?

    var hasLoadedResourceUsage: Bool {
        sampledAt != nil
            || !rows.isEmpty
            || !agentRows.isEmpty
            || !aggregateRows.isEmpty
            || !childMemoryRows.isEmpty
            || memoryDiagnostic != nil
    }

    var updatedText: String {
        guard let sampledAt else {
            return String(localized: "taskManager.updated.never", defaultValue: "Never")
        }
        return CmuxTaskManagerFormat.time(sampledAt)
    }

    init(
        rows: [CmuxTaskManagerRow],
        agentRows: [CmuxTaskManagerRow] = [],
        aggregateRows: [CmuxTaskManagerRow],
        childMemoryRows: [CmuxTaskManagerRow] = [],
        total: CmuxTaskManagerResources,
        sampledAt: Date?,
        memoryDiagnostic: CmuxTaskManagerMemoryDiagnostic? = nil
    ) {
        self.rows = rows
        self.agentRows = agentRows
        self.aggregateRows = aggregateRows
        self.childMemoryRows = childMemoryRows
        self.total = total
        self.sampledAt = sampledAt
        self.memoryDiagnostic = memoryDiagnostic
    }

    init(
        rows: [CmuxTaskManagerRow],
        agentRows: [CmuxTaskManagerRow] = [],
        total: CmuxTaskManagerResources,
        sampledAt: Date?,
        memoryDiagnostic: CmuxTaskManagerMemoryDiagnostic? = nil
    ) {
        self.init(
            rows: rows,
            agentRows: agentRows,
            aggregateRows: Self.programAggregateRows(from: rows),
            childMemoryRows: Self.childMemoryRows(from: memoryDiagnostic),
            total: total,
            sampledAt: sampledAt,
            memoryDiagnostic: memoryDiagnostic
        )
    }

    init(payload: [String: Any]) {
        let sample = payload["sample"] as? [String: Any] ?? [:]
        self.sampledAt = CmuxTaskManagerFormat.iso8601Date(sample["sampled_at"] as? String)
        self.total = CmuxTaskManagerResources(payload["totals"] as? [String: Any] ?? [:])

        var rows: [CmuxTaskManagerRow] = []
        let windows = payload["windows"] as? [[String: Any]] ?? []
        for window in windows {
            Self.appendWindow(window, to: &rows)
        }
        let agentRows = Self.agentRows(from: payload["coding_agents"] as? [[String: Any]] ?? [])
        self.rows = Self.rowsWithAgentAssets(
            rows,
            assetNameByProcessID: Self.agentAssetNameByProcessID(from: agentRows)
        )
        self.agentRows = agentRows
        let programTotalPayloads = payload["program_totals"] as? [[String: Any]] ?? []
        self.aggregateRows = programTotalPayloads.isEmpty
            ? Self.programAggregateRows(from: self.rows)
            : Self.programAggregateRows(fromPayloads: programTotalPayloads)
        let memoryDiagnostic = CmuxTaskManagerMemoryDiagnostic(payload["memory_diagnostic"] as? [String: Any])
        self.memoryDiagnostic = memoryDiagnostic
        self.childMemoryRows = Self.childMemoryRows(from: memoryDiagnostic)
    }

    private static func childMemoryRows(from diagnostic: CmuxTaskManagerMemoryDiagnostic?) -> [CmuxTaskManagerRow] {
        guard let diagnostic else { return [] }
        return diagnostic.groups.map { group in
            let attribution = group.topAttribution
            let workspaceId = attribution?.workspaceId
            let surfaceId = attribution?.surfaceId
            let surfaceType = attribution?.surfaceType?.lowercased()
            let detailParts = [
                processCountDetail(group.processCount),
                attributionDetail(attribution)
            ].compactMap { $0 }
            return CmuxTaskManagerRow(
                id: "childMemoryAggregate:\(group.id)",
                kind: .childMemoryAggregate,
                level: 0,
                title: group.name,
                detail: detailParts.joined(separator: " / "),
                resources: CmuxTaskManagerResources(
                    cpuPercent: 0,
                    residentBytes: group.rssBytes,
                    memoryBytes: group.rssBytes,
                    processCount: group.processCount,
                    processIds: group.processIds
                ),
                isDimmed: false,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                terminalSurfaceId: surfaceType == "terminal" ? surfaceId : nil,
                processId: nil,
                rootProcessIds: group.processIds,
                foregroundProcessGroupIds: [],
                agentAssetName: Self.agentAssetResolver.assetName(forNameCandidates: [group.name])
            )
        }
    }

    private static func attributionDetail(_ attribution: CmuxTaskManagerMemoryAttribution?) -> String? {
        guard let attribution else {
            return String(localized: "taskManager.memory.unattributed", defaultValue: "Unattributed")
        }
        var parts: [String] = []
        if let workspace = attribution.workspaceRef ?? attribution.workspaceId?.uuidString {
            parts.append(String(format: String(
                localized: "taskManager.memory.workspace",
                defaultValue: "Workspace %@"
            ), workspace))
        }
        if let pane = attribution.paneRef ?? attribution.paneId?.uuidString {
            parts.append(String(format: String(
                localized: "taskManager.memory.pane",
                defaultValue: "Pane %@"
            ), pane))
        }
        if let surface = attribution.surfaceRef ?? attribution.surfaceId?.uuidString {
            parts.append(String(format: String(
                localized: "taskManager.memory.surface",
                defaultValue: "Surface %@"
            ), surface))
        }
        if parts.isEmpty {
            return String(localized: "taskManager.memory.unattributed", defaultValue: "Unattributed")
        }
        return parts.joined(separator: " / ")
    }

    private static func agentRows(from payloads: [[String: Any]]) -> [CmuxTaskManagerRow] {
        payloads.compactMap { payload in
            guard let id = nonEmptyString(payload["id"]),
                  let title = nonEmptyString(payload["display_name"]) else { return nil }
            let resources = CmuxTaskManagerResources(payload["resources"] as? [String: Any] ?? [:])
            guard resources.processCount > 0 else { return nil }
            return CmuxTaskManagerRow(
                id: "codingAgentAggregate:\(id)",
                kind: .codingAgentAggregate,
                level: 0,
                title: title,
                detail: processCountDetail(resources.processCount),
                resources: resources,
                isDimmed: false,
                workspaceId: nil,
                surfaceId: nil,
                terminalSurfaceId: nil,
                processId: nil,
                rootProcessIds: resources.processIds,
                foregroundProcessGroupIds: [],
                agentAssetName: nonEmptyString(payload["asset_name"])
            )
        }
    }

    private static func agentAssetNameByProcessID(from agentRows: [CmuxTaskManagerRow]) -> [Int: String] {
        var assetNameByProcessID: [Int: String] = [:]
        for row in agentRows {
            guard let assetName = row.agentAssetName else { continue }
            for processID in row.resources.processIds {
                assetNameByProcessID[processID] = assetName
            }
        }
        return assetNameByProcessID
    }

    private static func rowsWithAgentAssets(
        _ rows: [CmuxTaskManagerRow],
        assetNameByProcessID: [Int: String]
    ) -> [CmuxTaskManagerRow] {
        guard !assetNameByProcessID.isEmpty else { return rows }
        return rows.map { row in
            if row.agentAssetName != nil {
                return row
            }
            guard row.kind != .window else {
                return row
            }

            var assetNames = Set<String>()
            for processID in row.resources.processIds {
                if let assetName = assetNameByProcessID[processID] {
                    assetNames.insert(assetName)
                }
            }
            if let processID = row.processId,
               let assetName = assetNameByProcessID[processID] {
                assetNames.insert(assetName)
            }
            for processID in row.rootProcessIds {
                if let assetName = assetNameByProcessID[processID] {
                    assetNames.insert(assetName)
                }
            }

            guard assetNames.count == 1, let assetName = assetNames.first else {
                return row
            }
            return row.withAgentAssetName(assetName)
        }
    }

    private struct ProgramAggregate {
        let title: String
        var cpuPercent: Double = 0
        var memoryBytes: Int64 = 0
        var residentBytes: Int64 = 0
        var processIds: [Int] = []

        mutating func append(_ row: CmuxTaskManagerRow) {
            guard let processId = row.processId else { return }
            cpuPercent += row.resources.cpuPercent
            memoryBytes = Self.clampedAdd(memoryBytes, row.resources.memoryBytes)
            residentBytes = Self.clampedAdd(residentBytes, row.resources.residentBytes)
            processIds.append(processId)
        }

        private static func clampedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? Int64.max : sum
        }
    }

    private static func programAggregateRows(from rows: [CmuxTaskManagerRow]) -> [CmuxTaskManagerRow] {
        var aggregatesByKey: [String: ProgramAggregate] = [:]
        var seenProcessIds: Set<Int> = []

        for row in rows where row.kind == .process {
            guard let processId = row.processId,
                  seenProcessIds.insert(processId).inserted else { continue }

            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let key = title.lowercased()
            if aggregatesByKey[key] == nil {
                aggregatesByKey[key] = ProgramAggregate(title: title)
            }
            aggregatesByKey[key]?.append(row)
        }

        return aggregatesByKey.values
            .filter { $0.processIds.count > 1 }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { aggregate in
                let processIds = aggregate.processIds.sorted()
                return CmuxTaskManagerRow(
                    id: "programAggregate:\(aggregate.title.lowercased())",
                    kind: .programAggregate,
                    level: 0,
                    title: aggregate.title,
                    detail: processCountDetail(processIds.count),
                    resources: CmuxTaskManagerResources(
                        cpuPercent: aggregate.cpuPercent,
                        residentBytes: aggregate.residentBytes,
                        memoryBytes: aggregate.memoryBytes,
                        processCount: processIds.count,
                        processIds: processIds
                    ),
                    isDimmed: false,
                    workspaceId: nil,
                    surfaceId: nil,
                    terminalSurfaceId: nil,
                    processId: nil,
                    rootProcessIds: processIds,
                    foregroundProcessGroupIds: [],
                    agentAssetName: Self.agentAssetResolver.assetName(forNameCandidates: [aggregate.title])
                )
            }
    }

    private static func programAggregateRows(fromPayloads payloads: [[String: Any]]) -> [CmuxTaskManagerRow] {
        payloads.compactMap { payload in
            guard let title = nonEmptyString(payload["name"]) else { return nil }
            let resources = CmuxTaskManagerResources(payload["resources"] as? [String: Any] ?? [:])
            guard resources.processCount > 0 else { return nil }
            let id = nonEmptyString(payload["id"]) ?? title.lowercased()
            return CmuxTaskManagerRow(
                id: "programAggregate:\(id)",
                kind: .programAggregate,
                level: 0,
                title: title,
                detail: processCountDetail(resources.processCount),
                resources: resources,
                isDimmed: false,
                workspaceId: nil,
                surfaceId: nil,
                terminalSurfaceId: nil,
                processId: nil,
                rootProcessIds: resources.processIds,
                foregroundProcessGroupIds: [],
                agentAssetName: Self.agentAssetResolver.assetName(forNameCandidates: [title])
            )
        }
    }

    private static func processCountDetail(_ processCount: Int) -> String {
        if processCount == 1 {
            return String(localized: "taskManager.aggregate.processCount.one", defaultValue: "1 process")
        }
        return String(format: String(
            localized: "taskManager.aggregate.processCount.other",
            defaultValue: "%lld processes"
        ), Int64(processCount))
    }

    private static func appendWindow(_ window: [String: Any], to rows: inout [CmuxTaskManagerRow]) {
        let handle = displayHandle(window)
        var detailParts: [String] = []
        if bool(window["key"]) {
            detailParts.append(String(localized: "taskManager.row.keyWindow", defaultValue: "Key window"))
        }
        if bool(window["visible"]) == false {
            detailParts.append(String(localized: "taskManager.row.hidden", defaultValue: "Hidden"))
        }
        rows.append(row(
            window,
            kind: .window,
            level: 0,
            title: String(localized: "taskManager.row.window", defaultValue: "Window \(handle)"),
            detail: detailParts.joined(separator: " / ")
        ))

        let processes = window["processes"] as? [[String: Any]] ?? []
        let context = rowID(window, kind: .window)
        for process in processes {
            appendProcess(process, level: 1, context: context, workspaceId: nil, terminalSurfaceId: nil, to: &rows)
        }

        let workspaces = window["workspaces"] as? [[String: Any]] ?? []
        for workspace in workspaces {
            appendWorkspace(workspace, to: &rows)
        }
    }

    private static func appendWorkspace(_ workspace: [String: Any], to rows: inout [CmuxTaskManagerRow]) {
        let workspaceId = uuid(workspace["id"])
        let title = nonEmptyString(workspace["title"]) ?? displayHandle(workspace)
        var detailParts: [String] = []
        if bool(workspace["selected"]) {
            detailParts.append(String(localized: "taskManager.row.selected", defaultValue: "Selected"))
        }
        if bool(workspace["pinned"]) {
            detailParts.append(String(localized: "taskManager.row.pinned", defaultValue: "Pinned"))
        }
        rows.append(row(
            workspace,
            kind: .workspace,
            level: 1,
            title: title,
            detail: detailParts.joined(separator: " / "),
            workspaceId: workspaceId
        ))

        let tags = workspace["tags"] as? [[String: Any]] ?? []
        for tag in tags {
            appendTag(tag, workspaceId: workspaceId, to: &rows)
        }

        let panes = workspace["panes"] as? [[String: Any]] ?? []
        for pane in panes {
            appendPane(pane, workspaceId: workspaceId, to: &rows)
        }
    }

    private static func appendTag(
        _ tag: [String: Any],
        workspaceId: UUID?,
        to rows: inout [CmuxTaskManagerRow]
    ) {
        let key = nonEmptyString(tag["key"]) ?? String(localized: "taskManager.row.unknownTag", defaultValue: "Unknown tag")
        let value = nonEmptyString(tag["value"])
        let title = value.map { "\(key): \($0)" } ?? key
        let detail = int(tag["pid"]).map {
            String(localized: "taskManager.row.pid", defaultValue: "PID \($0)")
        } ?? ""
        rows.append(row(
            tag,
            kind: .tag,
            level: 2,
            title: title,
            detail: detail,
            isDimmed: bool(tag["visible"]) == false,
            workspaceId: workspaceId,
            agentAssetName: Self.agentAssetResolver.assetName(forNameCandidates: [key, value])
        ))

        let processes = tag["processes"] as? [[String: Any]] ?? []
        let context = rowID(tag, kind: .tag)
        for process in processes {
            appendProcess(process, level: 3, context: context, workspaceId: workspaceId, terminalSurfaceId: nil, to: &rows)
        }
    }

    private static func appendPane(_ pane: [String: Any], workspaceId: UUID?, to rows: inout [CmuxTaskManagerRow]) {
        let handle = displayHandle(pane)
        rows.append(row(
            pane,
            kind: .pane,
            level: 2,
            title: String(localized: "taskManager.row.pane", defaultValue: "Pane \(handle)"),
            detail: bool(pane["focused"]) ? String(localized: "taskManager.row.focused", defaultValue: "Focused") : "",
            workspaceId: workspaceId
        ))

        let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
        for surface in surfaces {
            appendSurface(surface, workspaceId: workspaceId, to: &rows)
        }
    }

    private static func appendSurface(_ surface: [String: Any], workspaceId: UUID?, to rows: inout [CmuxTaskManagerRow]) {
        let type = (nonEmptyString(surface["type"]) ?? "unknown").lowercased()
        let title = nonEmptyString(surface["title"]) ?? displayHandle(surface)
        let surfaceId = uuid(surface["id"])
        let terminalSurfaceId = type == "terminal" ? surfaceId : nil
        var detailParts = [surfaceTypeLabel(type)]
        if bool(surface["selected"]) {
            detailParts.append(String(localized: "taskManager.row.selected", defaultValue: "Selected"))
        }
        if let tty = nonEmptyString(surface["tty"]) {
            detailParts.append(tty)
        }
        if let url = nonEmptyString(surface["url"]) {
            detailParts.append(url)
        }
        rows.append(row(
            surface,
            kind: type == "browser" ? .browserSurface : .terminalSurface,
            level: 3,
            title: title,
            detail: detailParts.joined(separator: " / "),
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            terminalSurfaceId: terminalSurfaceId,
            agentAssetName: Self.agentAssetResolver.assetName(forNameCandidates: [title])
        ))

        let webviews = surface["webviews"] as? [[String: Any]] ?? []
        if !webviews.isEmpty {
            for webview in webviews {
                appendWebView(webview, workspaceId: workspaceId, surfaceId: surfaceId, to: &rows)
            }
        }
        let processes = surface["processes"] as? [[String: Any]] ?? []
        let context = rowID(surface, kind: type == "browser" ? .browserSurface : .terminalSurface)
        for process in processes {
            appendProcess(
                process,
                level: 4,
                context: context,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                terminalSurfaceId: terminalSurfaceId,
                to: &rows
            )
        }
    }

    private static func appendWebView(
        _ webview: [String: Any],
        workspaceId: UUID?,
        surfaceId: UUID?,
        to rows: inout [CmuxTaskManagerRow]
    ) {
        let title = nonEmptyString(webview["title"])
            ?? String(localized: "taskManager.row.webview", defaultValue: "WebView")
        var detailParts: [String] = []
        if let pid = int(webview["pid"]) {
            detailParts.append(String(localized: "taskManager.row.pid", defaultValue: "PID \(pid)"))
        }
        if let sharedCount = int(webview["shared_process_count"]), sharedCount > 1 {
            detailParts.append(String(localized: "taskManager.row.sharedProcess", defaultValue: "Shared x\(sharedCount)"))
        }
        if let url = nonEmptyString(webview["url"]) {
            detailParts.append(url)
        }
        rows.append(row(
            webview,
            kind: .webview,
            level: 4,
            title: title,
            detail: detailParts.joined(separator: " / "),
            workspaceId: workspaceId,
            surfaceId: surfaceId
        ))

        let processes = webview["processes"] as? [[String: Any]] ?? []
        let context = rowID(webview, kind: .webview)
        for process in processes {
            appendProcess(
                process,
                level: 5,
                context: context,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                terminalSurfaceId: nil,
                to: &rows
            )
        }
    }

    private static func appendProcess(
        _ process: [String: Any],
        level: Int,
        context: String,
        workspaceId: UUID?,
        surfaceId: UUID? = nil,
        terminalSurfaceId: UUID?,
        to rows: inout [CmuxTaskManagerRow]
    ) {
        let pid = int(process["pid"])
        let title = nonEmptyString(process["name"])
            ?? pid.map { String(localized: "taskManager.row.processWithPID", defaultValue: "Process \($0)") }
            ?? String(localized: "taskManager.row.process", defaultValue: "Process")
        let detail = pid.map {
            String(localized: "taskManager.row.pid", defaultValue: "PID \($0)")
        } ?? ""
        let processRootIds = pid.map { [$0] } ?? []
        let metadataSurfaceId = uuid(process["cmux_surface_id"])
        let processSurfaceId = surfaceId ?? metadataSurfaceId
        let processTerminalSurfaceId = terminalSurfaceId ?? (surfaceId == nil ? metadataSurfaceId : nil)
        let processRow = row(
            process,
            kind: .process,
            level: level,
            title: title,
            detail: detail,
            context: context,
            workspaceId: workspaceId,
            surfaceId: processSurfaceId,
            terminalSurfaceId: processTerminalSurfaceId,
            processId: pid,
            rootProcessIds: processRootIds,
            agentAssetName: Self.agentAssetResolver.assetName(forNameCandidates: [
                nonEmptyString(process["name"]),
                nonEmptyString(process["path"]).map { URL(fileURLWithPath: $0).lastPathComponent }
            ])
        )
        rows.append(processRow)

        let children = process["children"] as? [[String: Any]] ?? []
        for child in children {
            appendProcess(
                child,
                level: level + 1,
                context: processRow.id,
                workspaceId: workspaceId,
                surfaceId: processSurfaceId,
                terminalSurfaceId: processTerminalSurfaceId,
                to: &rows
            )
        }
    }

    private static func row(
        _ payload: [String: Any],
        kind: CmuxTaskManagerRow.Kind,
        level: Int,
        title: String,
        detail: String,
        isDimmed: Bool = false,
        context: String? = nil,
        workspaceId: UUID? = nil,
        surfaceId: UUID? = nil,
        terminalSurfaceId: UUID? = nil,
        processId: Int? = nil,
        rootProcessIds: [Int]? = nil,
        foregroundProcessGroupIds: [Int]? = nil,
        agentAssetName: String? = nil
    ) -> CmuxTaskManagerRow {
        CmuxTaskManagerRow(
            id: rowID(payload, kind: kind, context: context),
            kind: kind,
            level: level,
            title: title,
            detail: detail,
            resources: CmuxTaskManagerResources(payload["resources"] as? [String: Any] ?? [:]),
            isDimmed: isDimmed,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            terminalSurfaceId: terminalSurfaceId,
            processId: processId,
            rootProcessIds: rootProcessIds ?? intArray(payload["top_level_pids"]),
            foregroundProcessGroupIds: foregroundProcessGroupIds ?? intArray(payload["foreground_pgids"]),
            agentAssetName: agentAssetName
        )
    }

    private static func rowID(
        _ payload: [String: Any],
        kind: CmuxTaskManagerRow.Kind,
        context: String? = nil
    ) -> String {
        if kind == .process, let context {
            if let id = nonEmptyString(payload["id"]) {
                return "\(kind.rawValue):\(context):\(id)"
            }
            if let ref = nonEmptyString(payload["ref"]) {
                return "\(kind.rawValue):\(context):\(ref)"
            }
            if let pid = int(payload["pid"]) {
                return "\(kind.rawValue):\(context):pid:\(pid)"
            }
        }
        if let id = nonEmptyString(payload["id"]) {
            return "\(kind.rawValue):\(id)"
        }
        if let pid = int(payload["pid"]) {
            return "\(kind.rawValue):pid:\(pid)"
        }
        if let ref = nonEmptyString(payload["ref"]) {
            return "\(kind.rawValue):\(ref)"
        }
        return "\(kind.rawValue):\(UUID().uuidString)"
    }

    private static func displayHandle(_ payload: [String: Any]) -> String {
        nonEmptyString(payload["ref"]) ?? nonEmptyString(payload["id"]) ?? "?"
    }

    private static func surfaceTypeLabel(_ type: String) -> String {
        switch type {
        case "browser":
            return String(localized: "taskManager.row.surfaceType.browser", defaultValue: "Browser")
        case "terminal":
            return String(localized: "taskManager.row.surfaceType.terminal", defaultValue: "Terminal")
        case "unknown", "":
            return String(localized: "taskManager.row.surfaceType.unknown", defaultValue: "Unknown")
        default:
            return type
        }
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func uuid(_ raw: Any?) -> UUID? {
        guard let value = nonEmptyString(raw) else { return nil }
        return UUID(uuidString: value)
    }

    private static func bool(_ raw: Any?) -> Bool {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        return false
    }

    private static func int(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func intArray(_ raw: Any?) -> [Int] {
        if let values = raw as? [Int] { return values }
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap(int)
    }
}
