import Darwin
import Foundation
import SwiftUI

struct CmuxTaskManagerRow: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case window
        case workspace
        case tag
        case pane
        case terminalSurface
        case browserSurface
        case webview
        case process
        case programAggregate
        case codingAgentAggregate
        case childMemoryAggregate

        var systemImage: String {
            switch self {
            case .window: return "macwindow"
            case .workspace: return "rectangle.stack"
            case .tag: return "tag"
            case .pane: return "square.split.2x1"
            case .terminalSurface: return "terminal"
            case .browserSurface: return "globe"
            case .webview: return "network"
            case .process: return "gearshape"
            case .programAggregate: return "gearshape.2"
            case .codingAgentAggregate: return "sparkles"
            case .childMemoryAggregate: return "memorychip"
            }
        }

        var tint: Color {
            switch self {
            case .window: return .secondary
            case .workspace: return .accentColor
            case .tag: return .orange
            case .pane: return .secondary
            case .terminalSurface: return .green
            case .browserSurface: return .blue
            case .webview: return .purple
            case .process: return .secondary
            case .programAggregate: return .accentColor
            case .codingAgentAggregate: return .accentColor
            case .childMemoryAggregate: return .pink
            }
        }
    }

    let id: String
    let kind: Kind
    let level: Int
    let title: String
    let detail: String
    let resources: CmuxTaskManagerResources
    let isDimmed: Bool
    let workspaceId: UUID?
    let surfaceId: UUID?
    let terminalSurfaceId: UUID?
    let processId: Int?
    let rootProcessIds: [Int]
    let foregroundProcessGroupIds: [Int]
    let agentAssetName: String?

    /// Replaces the synthesized memberwise init so the PID arrays are
    /// stored in a canonical (deduped + ascending) order. The snapshot
    /// producers happen to sort today, but this guarantees the synthesized
    /// `Equatable` stays stable across reorderings so `.equatable()` keeps
    /// suppressing row re-renders even if a future producer forgets.
    /// Issue #4529.
    init(
        id: String,
        kind: Kind,
        level: Int,
        title: String,
        detail: String,
        resources: CmuxTaskManagerResources,
        isDimmed: Bool,
        workspaceId: UUID?,
        surfaceId: UUID?,
        terminalSurfaceId: UUID?,
        processId: Int?,
        rootProcessIds: [Int],
        foregroundProcessGroupIds: [Int],
        agentAssetName: String?
    ) {
        self.id = id
        self.kind = kind
        self.level = level
        self.title = title
        self.detail = detail
        self.resources = resources
        self.isDimmed = isDimmed
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.terminalSurfaceId = terminalSurfaceId
        self.processId = processId
        self.rootProcessIds = Self.canonicalIds(rootProcessIds)
        self.foregroundProcessGroupIds = Self.canonicalIds(foregroundProcessGroupIds)
        self.agentAssetName = agentAssetName
    }

    private static func canonicalIds(_ ids: [Int]) -> [Int] {
        guard !ids.isEmpty else { return ids }
        return Array(Set(ids)).sorted()
    }

    var canViewWorkspace: Bool {
        workspaceId != nil
    }

    var canViewTerminal: Bool {
        workspaceId != nil && terminalSurfaceId != nil
    }

    var canKillProcess: Bool {
        !killableProcessIds.isEmpty
    }

    var killableProcessIds: [Int] {
        var ids = resources.processIds
        if let processId {
            ids.append(processId)
        }
        let currentPID = Int(getpid())
        return Array(Set(ids))
            .filter { $0 > 1 && $0 != currentPID }
            .sorted()
    }

    var gracefulProcessIds: [Int] {
        var ids = rootProcessIds
        if ids.isEmpty, let processId {
            ids.append(processId)
        }
        if ids.isEmpty {
            ids = resources.processIds
        }
        return safeProcessIds(ids)
    }

    var gracefulProcessGroupIds: [Int] {
        let currentProcessGroupId = Int(getpgrp())
        return Array(Set(foregroundProcessGroupIds))
            .filter { $0 > 1 && $0 != currentProcessGroupId }
            .sorted()
    }

    private func safeProcessIds(_ ids: [Int]) -> [Int] {
        let currentPID = Int(getpid())
        return Array(Set(ids))
            .filter { $0 > 1 && $0 != currentPID }
            .sorted()
    }

    func withAgentAssetName(_ assetName: String?) -> CmuxTaskManagerRow {
        guard agentAssetName != assetName else { return self }
        return CmuxTaskManagerRow(
            id: id,
            kind: kind,
            level: level,
            title: title,
            detail: detail,
            resources: resources,
            isDimmed: isDimmed,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            terminalSurfaceId: terminalSurfaceId,
            processId: processId,
            rootProcessIds: rootProcessIds,
            foregroundProcessGroupIds: foregroundProcessGroupIds,
            agentAssetName: assetName
        )
    }
}

struct CmuxTaskManagerSortOrder: Equatable {
    enum Column: Equatable {
        case name
        case cpu
        case memory
        case processes

        var defaultDirection: Direction {
            switch self {
            case .name: return .ascending
            case .cpu, .memory, .processes: return .descending
            }
        }
    }

    enum Direction: Equatable {
        case ascending
        case descending

        var toggled: Direction {
            switch self {
            case .ascending: return .descending
            case .descending: return .ascending
            }
        }
    }

    static let defaultOrder = CmuxTaskManagerSortOrder(column: .cpu, direction: .descending)

    let column: Column
    let direction: Direction

    func toggled(for selectedColumn: Column) -> CmuxTaskManagerSortOrder {
        if selectedColumn == column {
            return CmuxTaskManagerSortOrder(column: column, direction: direction.toggled)
        }
        return CmuxTaskManagerSortOrder(
            column: selectedColumn,
            direction: selectedColumn.defaultDirection
        )
    }

    func sortedRows(_ rows: [CmuxTaskManagerRow]) -> [CmuxTaskManagerRow] {
        guard !rows.isEmpty else { return rows }
        var index = 0
        let rootLevel = rows.reduce(Int.max) { min($0, $1.level) }
        let nodes = parseNodes(rows, index: &index, level: rootLevel)
        return flatten(sortNodes(nodes))
    }

    private func parseNodes(
        _ rows: [CmuxTaskManagerRow],
        index: inout Int,
        level: Int
    ) -> [SortNode] {
        var nodes: [SortNode] = []
        while index < rows.count {
            let row = rows[index]
            if row.level < level {
                break
            }
            if row.level > level {
                break
            }

            index += 1
            var children: [SortNode] = []
            while index < rows.count, rows[index].level > row.level {
                children.append(contentsOf: parseNodes(rows, index: &index, level: rows[index].level))
            }
            nodes.append(SortNode(row: row, children: children))
        }
        return nodes
    }

    private func sortNodes(_ nodes: [SortNode]) -> [SortNode] {
        let sorted = nodes.enumerated().sorted { lhs, rhs in
            let comparison = compare(lhs.element.row, rhs.element.row)
            if comparison != .orderedSame {
                return direction == .ascending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            }
            return lhs.offset < rhs.offset
        }

        return sorted.map { _, node in
            SortNode(row: node.row, children: sortNodes(node.children))
        }
    }

    private func flatten(_ nodes: [SortNode]) -> [CmuxTaskManagerRow] {
        nodes.flatMap { node in
            [node.row] + flatten(node.children)
        }
    }

    private func compare(_ lhs: CmuxTaskManagerRow, _ rhs: CmuxTaskManagerRow) -> ComparisonResult {
        switch column {
        case .name:
            return lhs.title.localizedStandardCompare(rhs.title)
        case .cpu:
            return valueComparison(lhs.resources.cpuPercent, rhs.resources.cpuPercent)
        case .memory:
            return valueComparison(lhs.resources.memoryBytes, rhs.resources.memoryBytes)
        case .processes:
            return valueComparison(lhs.resources.processCount, rhs.resources.processCount)
        }
    }

    private func valueComparison<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

private struct SortNode {
    let row: CmuxTaskManagerRow
    let children: [SortNode]
}

struct CmuxTaskManagerResources: Equatable {
    static let zero = CmuxTaskManagerResources(cpuPercent: 0, residentBytes: 0, processCount: 0)

    let cpuPercent: Double
    let memoryBytes: Int64
    let residentBytes: Int64
    let processCount: Int
    let processIds: [Int]

    init(
        cpuPercent: Double,
        residentBytes: Int64,
        memoryBytes: Int64? = nil,
        processCount: Int,
        processIds: [Int] = []
    ) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes ?? residentBytes
        self.residentBytes = residentBytes
        self.processCount = processCount
        self.processIds = Self.canonicalIds(processIds)
    }

    init(_ payload: [String: Any]) {
        self.cpuPercent = Self.double(payload["cpu_percent"])
        self.memoryBytes = Self.int64(payload["memory_bytes"] ?? payload["resident_bytes"])
        self.residentBytes = Self.int64(payload["resident_bytes"])
        self.processCount = Self.int(payload["process_count"]) ?? 0
        self.processIds = Self.canonicalIds(Self.intArray(payload["pids"]))
    }

    /// Canonical (deduped + ascending) ordering so synthesized
    /// `Equatable` stays stable across snapshot reorderings. See
    /// `CmuxTaskManagerRow.canonicalIds` for the same rationale.
    private static func canonicalIds(_ ids: [Int]) -> [Int] {
        guard !ids.isEmpty else { return ids }
        return Array(Set(ids)).sorted()
    }

    private static func double(_ raw: Any?) -> Double {
        if let value = raw as? Double { return value }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String,
           let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
    }

    private static func int64(_ raw: Any?) -> Int64 {
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? NSNumber { return value.int64Value }
        if let value = raw as? String,
           let parsed = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
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

struct CmuxTaskManagerMemoryDiagnostic: Sendable {
    let summary: String
    let appFootprintBytes: Int64
    let appResidentBytes: Int64
    let childRSSBytes: Int64
    let childProcessCount: Int
    let groups: [CmuxTaskManagerMemoryGroup]

    init?(_ payload: [String: Any]?) {
        guard let payload else { return nil }
        let app = payload["app"] as? [String: Any] ?? [:]
        let children = payload["children"] as? [String: Any] ?? [:]
        self.summary = Self.string(payload["summary"]) ?? ""
        self.appFootprintBytes = Self.int64(app["physical_footprint_bytes"])
        self.appResidentBytes = Self.int64(app["resident_bytes"])
        self.childRSSBytes = Self.int64(children["recursive_rss_bytes"])
        self.childProcessCount = Self.int(children["process_count"]) ?? 0
        self.groups = (children["groups"] as? [[String: Any]] ?? [])
            .compactMap(CmuxTaskManagerMemoryGroup.init)
    }

    static func string(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func int64(_ raw: Any?) -> Int64 {
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? NSNumber { return value.int64Value }
        if let value = raw as? String,
           let parsed = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
    }

    static func int(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    static func intArray(_ raw: Any?) -> [Int] {
        if let values = raw as? [Int] { return values }
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap(int)
    }
}

struct CmuxTaskManagerMemoryGroup: Sendable {
    let id: String
    let name: String
    let rssBytes: Int64
    let processCount: Int
    let processIds: [Int]
    let topAttribution: CmuxTaskManagerMemoryAttribution?

    init?(_ payload: [String: Any]) {
        guard let name = CmuxTaskManagerMemoryDiagnostic.string(payload["name"]) else {
            return nil
        }
        let processCount = CmuxTaskManagerMemoryDiagnostic.int(payload["process_count"]) ?? 0
        guard processCount > 0 else { return nil }
        self.id = CmuxTaskManagerMemoryDiagnostic.string(payload["id"]) ?? name.lowercased()
        self.name = name
        self.rssBytes = CmuxTaskManagerMemoryDiagnostic.int64(payload["rss_bytes"])
        self.processCount = processCount
        self.processIds = CmuxTaskManagerMemoryDiagnostic.intArray(payload["pids"])
        self.topAttribution = CmuxTaskManagerMemoryAttribution(payload["top_attribution"] as? [String: Any])
    }
}

struct CmuxTaskManagerMemoryAttribution: Sendable {
    let workspaceId: UUID?
    let workspaceRef: String?
    let paneId: UUID?
    let paneRef: String?
    let surfaceId: UUID?
    let surfaceRef: String?
    let surfaceType: String?

    init?(_ payload: [String: Any]?) {
        guard let payload else { return nil }
        self.workspaceId = Self.uuid(payload["workspace_id"])
        self.workspaceRef = CmuxTaskManagerMemoryDiagnostic.string(payload["workspace_ref"])
        self.paneId = Self.uuid(payload["pane_id"])
        self.paneRef = CmuxTaskManagerMemoryDiagnostic.string(payload["pane_ref"])
        self.surfaceId = Self.uuid(payload["surface_id"])
        self.surfaceRef = CmuxTaskManagerMemoryDiagnostic.string(payload["surface_ref"])
        self.surfaceType = CmuxTaskManagerMemoryDiagnostic.string(payload["surface_type"])
        if workspaceId == nil,
           workspaceRef == nil,
           paneId == nil,
           paneRef == nil,
           surfaceId == nil,
           surfaceRef == nil,
           surfaceType == nil {
            return nil
        }
    }

    private static func uuid(_ raw: Any?) -> UUID? {
        if let value = raw as? UUID {
            return value
        }
        guard let value = CmuxTaskManagerMemoryDiagnostic.string(raw) else {
            return nil
        }
        return UUID(uuidString: value)
    }
}

enum CmuxTaskManagerFormat {
    private static let isoFormatter = ISO8601DateFormatter()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    static func cpu(_ value: Double) -> String {
        String(format: "%.1f%%", max(0, value))
    }

    static func bytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    static func iso8601Date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return isoFormatter.date(from: raw)
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
