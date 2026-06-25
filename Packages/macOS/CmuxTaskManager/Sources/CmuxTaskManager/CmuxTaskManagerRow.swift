import Darwin
public import Foundation

/// One row in the Task Manager outline: a window, workspace, tag, pane,
/// surface, process, or an aggregate, with its resource usage and the PID
/// sets needed to act on it (view, kill, signal). Pure value model with no
/// SwiftUI coupling. The `Kind` presentation (SF Symbol + tint color) lives
/// in the paired `CmuxTaskManagerUI` package as a `Kind+Presentation`
/// extension so this domain type stays UI-free.
public struct CmuxTaskManagerRow: Identifiable, Equatable {
    /// The category of entity a row represents. Raw values are stable wire
    /// identifiers used by snapshot producers and consumers.
    public enum Kind: String, Equatable, Sendable {
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
    }

    public let id: String
    public let kind: Kind
    public let level: Int
    public let title: String
    public let detail: String
    public let resources: CmuxTaskManagerResources
    public let isDimmed: Bool
    public let workspaceId: UUID?
    public let surfaceId: UUID?
    public let terminalSurfaceId: UUID?
    public let processId: Int?
    public let rootProcessIds: [Int]
    public let foregroundProcessGroupIds: [Int]
    public let agentAssetName: String?

    /// Replaces the synthesized memberwise init so the PID arrays are
    /// stored in a canonical (deduped + ascending) order. The snapshot
    /// producers happen to sort today, but this guarantees the synthesized
    /// `Equatable` stays stable across reorderings so `.equatable()` keeps
    /// suppressing row re-renders even if a future producer forgets.
    /// Issue #4529.
    public init(
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

    /// True when the row can navigate to a workspace.
    public var canViewWorkspace: Bool {
        workspaceId != nil
    }

    /// True when the row can navigate to a terminal surface.
    public var canViewTerminal: Bool {
        workspaceId != nil && terminalSurfaceId != nil
    }

    /// True when the row has at least one killable process.
    public var canKillProcess: Bool {
        !killableProcessIds.isEmpty
    }

    /// PIDs eligible for a hard kill: the row's contributing PIDs plus its
    /// own `processId`, excluding PID 1 and this app's own PID.
    public var killableProcessIds: [Int] {
        var ids = resources.processIds
        if let processId {
            ids.append(processId)
        }
        let currentPID = Int(getpid())
        return Array(Set(ids))
            .filter { $0 > 1 && $0 != currentPID }
            .sorted()
    }

    /// PIDs eligible for a graceful (SIGTERM) shutdown, preferring the
    /// recorded root PIDs and falling back to `processId` then contributing
    /// PIDs.
    public var gracefulProcessIds: [Int] {
        var ids = rootProcessIds
        if ids.isEmpty, let processId {
            ids.append(processId)
        }
        if ids.isEmpty {
            ids = resources.processIds
        }
        return safeProcessIds(ids)
    }

    /// Foreground process-group IDs eligible for a graceful group signal,
    /// excluding PGID 1 and this app's own process group.
    public var gracefulProcessGroupIds: [Int] {
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

    /// Returns a copy with a different agent asset name, or `self` when
    /// unchanged.
    public func withAgentAssetName(_ assetName: String?) -> CmuxTaskManagerRow {
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
