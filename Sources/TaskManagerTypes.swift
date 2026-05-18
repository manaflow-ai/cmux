import Darwin
import Foundation
import SwiftUI

struct CmuxTaskManagerRow: Identifiable {
    enum Kind: String {
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
            return valueComparison(lhs.resources.residentBytes, rhs.resources.residentBytes)
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

struct CmuxTaskManagerResources {
    static let zero = CmuxTaskManagerResources(cpuPercent: 0, residentBytes: 0, processCount: 0)

    let cpuPercent: Double
    let residentBytes: Int64
    let processCount: Int
    let processIds: [Int]

    init(cpuPercent: Double, residentBytes: Int64, processCount: Int, processIds: [Int] = []) {
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.processCount = processCount
        self.processIds = processIds
    }

    init(_ payload: [String: Any]) {
        self.cpuPercent = Self.double(payload["cpu_percent"])
        self.residentBytes = Self.int64(payload["resident_bytes"])
        self.processCount = Self.int(payload["process_count"]) ?? 0
        self.processIds = Self.intArray(payload["pids"])
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

struct CmuxTaskManagerCodingAgentDefinition: Equatable {
    let id: String
    let displayName: String
    let assetName: String?
    let launchKinds: [String]
    let directBasenames: [String]
    let argumentNeedles: [String]

    static let builtIns: [CmuxTaskManagerCodingAgentDefinition] = [
        CmuxTaskManagerCodingAgentDefinition(
            id: "claude",
            displayName: "Claude Code",
            assetName: "AgentIcons/Claude",
            launchKinds: ["claude", "claudeteams", "claude-teams", "omc"],
            directBasenames: ["claude", "claude-code", "claude_code", "claude-teams", "omc"],
            argumentNeedles: [
                "claude-code",
                "claude_code",
                "claude-teams",
                "@anthropic-ai/claude-code",
                "oh-my-claude",
                "omc",
                "/.local/bin/claude",
                "/.local/share/claude/versions/",
                "/library/application support/claude/claude-code/",
            ]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "codex",
            displayName: "Codex",
            assetName: "AgentIcons/Codex",
            launchKinds: ["codex", "omx"],
            directBasenames: ["codex", "omx"],
            argumentNeedles: ["codex", "@openai/codex", "oh-my-codex"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "opencode",
            displayName: "OpenCode",
            assetName: "AgentIcons/OpenCode",
            launchKinds: ["opencode", "omo"],
            directBasenames: ["opencode", "opencode-ai", "open-code", "omo"],
            argumentNeedles: ["opencode", "opencode-ai", "open-code", "oh-my-openagent"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "pi",
            displayName: "Pi",
            assetName: "AgentIcons/Pi",
            launchKinds: ["pi"],
            directBasenames: ["pi", "pi-coding-agent"],
            argumentNeedles: ["@mariozechner/pi-coding-agent", "pi-coding-agent"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "amp",
            displayName: "Amp",
            assetName: nil,
            launchKinds: ["amp"],
            directBasenames: ["amp"],
            argumentNeedles: ["@ampcode"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "cursor",
            displayName: "Cursor",
            assetName: nil,
            launchKinds: ["cursor"],
            directBasenames: ["cursor-agent"],
            argumentNeedles: ["cursor-agent"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "gemini",
            displayName: "Gemini",
            assetName: nil,
            launchKinds: ["gemini"],
            directBasenames: ["gemini"],
            argumentNeedles: ["gemini"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "rovodev",
            displayName: "Rovo Dev",
            assetName: "AgentIcons/RovoDev",
            launchKinds: ["rovodev", "rovo"],
            directBasenames: ["rovodev"],
            argumentNeedles: ["rovodev"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "hermes-agent",
            displayName: "Hermes Agent",
            assetName: "AgentIcons/HermesAgent",
            launchKinds: ["hermes-agent"],
            directBasenames: ["hermes", "hermes-agent"],
            argumentNeedles: ["hermes-agent"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "copilot",
            displayName: "Copilot",
            assetName: nil,
            launchKinds: ["copilot"],
            directBasenames: ["copilot"],
            argumentNeedles: ["copilot"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "codebuddy",
            displayName: "CodeBuddy",
            assetName: nil,
            launchKinds: ["codebuddy"],
            directBasenames: ["codebuddy"],
            argumentNeedles: ["codebuddy"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "factory",
            displayName: "Factory",
            assetName: nil,
            launchKinds: ["factory"],
            directBasenames: ["droid", "factory"],
            argumentNeedles: ["factory"]
        ),
        CmuxTaskManagerCodingAgentDefinition(
            id: "qoder",
            displayName: "Qoder",
            assetName: nil,
            launchKinds: ["qoder"],
            directBasenames: ["qoder", "qodercli"],
            argumentNeedles: ["qoder", "qodercli"]
        ),
    ]

    static func shouldReadArguments(processName: String, processPath: String?) -> Bool {
        if let normalizedPath = normalized(processPath),
           argumentInspectionPathNeedles.contains(where: { normalizedPath.contains($0) }) {
            return true
        }

        let basenames = candidateBasenames(
            processName: processName,
            processPath: processPath,
            arguments: []
        )
        return basenames.contains { candidate in
            argumentHostBasenames.contains(candidate)
                || ambiguousDirectBasenames.contains(candidate)
                || isVersionedExecutableBasename(candidate)
        }
    }

    static func matchingDefinition(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> CmuxTaskManagerCodingAgentDefinition? {
        let definitions = builtIns
        let launchKind = normalized(environment["CMUX_AGENT_LAUNCH_KIND"])
        if let launchKind,
           let definition = definitions.first(where: { $0.launchKinds.contains(launchKind) }) {
            return definition
        }

        let basenames = candidateBasenames(
            processName: processName,
            processPath: processPath,
            arguments: arguments
        )
        if let definition = definitions.first(where: { definition in
            basenames.contains { definition.directBasenames.contains($0) }
        }) {
            return definition
        }

        guard !arguments.isEmpty else { return nil }
        return definitions.first { definition in
            definition.argumentNeedles.contains { needle in
                arguments.contains { argumentMatchesNeedle(argument: $0, needle: needle) }
            }
        }
    }

    private static let argumentHostBasenames: Set<String> = [
        "node", "bun", "deno", "npm", "npx", "pnpm", "yarn", "tsx"
    ]

    private static let ambiguousDirectBasenames: Set<String> = [
        "acli"
    ]

    private static let argumentInspectionPathNeedles = [
        "/.local/share/claude/versions/",
        "/library/application support/claude/claude-code/",
    ]

    private static func candidateBasenames(
        processName: String,
        processPath: String?,
        arguments: [String]
    ) -> Set<String> {
        var values = Set<String>()
        appendBasename(processName, to: &values)
        if let processPath {
            appendBasename(processPath, to: &values)
        }
        if let executable = arguments.first {
            appendBasename(executable, to: &values)
        }
        return values
    }

    private static func appendBasename(_ value: String, to values: inout Set<String>) {
        guard let normalized = normalized((value as NSString).lastPathComponent) else { return }
        values.insert(normalized)
    }

    private static func isVersionedExecutableBasename(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
        }
    }

    private static func argumentMatchesNeedle(argument: String, needle: String) -> Bool {
        guard let normalizedArgument = normalized(argument),
              let normalizedNeedle = normalized(needle) else { return false }
        if normalizedNeedle.contains("/") {
            return containsNeedleWithBoundaries(normalizedNeedle, in: normalizedArgument)
        }
        return argumentTokens(from: normalizedArgument).contains(normalizedNeedle)
    }

    private static func containsNeedleWithBoundaries(_ needle: String, in value: String) -> Bool {
        var searchRange = value.startIndex..<value.endIndex
        while let range = value.range(of: needle, range: searchRange) {
            let previous = range.lowerBound == value.startIndex ? nil : value[value.index(before: range.lowerBound)]
            let next = range.upperBound == value.endIndex ? nil : value[range.upperBound]
            let hasLeadingBoundary = needle.hasPrefix("/") || isNeedleBoundary(previous)
            let hasTrailingBoundary = needle.hasSuffix("/") || isNeedleBoundary(next)
            if hasLeadingBoundary, hasTrailingBoundary {
                return true
            }
            searchRange = range.upperBound..<value.endIndex
        }
        return false
    }

    private static func isNeedleBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        return character.unicodeScalars.allSatisfy { scalar in
            argumentBoundaryScalars.contains(scalar)
        }
    }

    private static func argumentTokens(from value: String) -> Set<String> {
        let tokens = value
            .components(separatedBy: argumentTokenSeparators)
            .filter { !$0.isEmpty }
        return Set(tokens.flatMap { token in
            let stem = (token as NSString).deletingPathExtension
            return stem.isEmpty || stem == token ? [token] : [token, stem]
        })
    }

    private static let argumentTokenSeparators = CharacterSet(charactersIn: "/\\ \t\r\n\u{0}:=?&#\"'`<>(),;[]{}")

    private static let argumentBoundaryScalars = CharacterSet(charactersIn: "/\\ \t\r\n\u{0}:=?&#\"'`<>(),;[]{}").union(.newlines)

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
