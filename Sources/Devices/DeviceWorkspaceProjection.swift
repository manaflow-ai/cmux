import CMUXMobileCore
import Foundation

/// Maps another Mac's synced workspace records onto the surface catalog: one
/// `SurfaceRemoteWorkspace` per remote workspace, and one `SurfaceResource` per
/// terminal (plus browsers, for the layout's sake) with an exact remote view so
/// the tree renders it under its workspace exactly as a cloud terminal.
///
/// Pure so the mapping is unit-testable from records alone.
struct DeviceWorkspaceProjection: Sendable {
    let machine: SurfaceMachineID
    /// Whether the link is live; offline records keep their rows but every
    /// resource reads `unavailable`, exactly like a cloud machine whose link dropped.
    let isLive: Bool

    init(machine: SurfaceMachineID, isLive: Bool) {
        self.machine = machine
        self.isLive = isLive
    }

    static func remoteWorkspace(_ record: WorkspaceSyncRecord) -> SurfaceRemoteWorkspace {
        SurfaceRemoteWorkspace(
            id: record.id,
            name: record.title,
            index: record.sortIndex,
            focused: record.isSelected,
            detail: record.currentDirectory,
            unreadCount: record.unreadCount ?? (record.hasUnread ? 1 : 0),
            isPinned: record.isPinned
        )
    }

    func remoteWorkspaces(_ records: [WorkspaceSyncRecord]) -> [SurfaceRemoteWorkspace] {
        records.map(Self.remoteWorkspace)
    }

    func resources(_ records: [WorkspaceSyncRecord]) -> [SurfaceResource] {
        var resources: [SurfaceResource] = []
        var seen = Set<SurfaceResourceID>()
        for record in records {
            let workspace = Self.remoteWorkspace(record)
            for (index, terminal) in record.terminals.enumerated() {
                let id = SurfaceResourceID(machine: machine, kind: .terminal, key: terminal.id)
                guard seen.insert(id).inserted else { continue }
                resources.append(SurfaceResource(
                    id: id,
                    title: terminal.title,
                    detail: terminal.currentDirectory,
                    lifecycle: lifecycle(isReady: terminal.isReady),
                    agent: Self.agentBadge(source: terminal.agentSource, state: terminal.agentState),
                    remoteWorkspace: workspace,
                    remoteViews: [SurfaceRemoteView(
                        tabID: terminal.id,
                        workspace: workspace,
                        name: nil,
                        index: index,
                        focused: terminal.isFocused
                    )],
                    port: nil,
                    url: nil
                ))
            }
            for (index, surface) in (record.surfaces ?? []).enumerated() where surface.kind == "browser" {
                let id = SurfaceResourceID(machine: machine, kind: .browser, key: surface.surfaceID)
                guard seen.insert(id).inserted else { continue }
                resources.append(SurfaceResource(
                    id: id,
                    title: surface.title,
                    detail: nil,
                    lifecycle: lifecycle(isReady: true),
                    agent: nil,
                    remoteWorkspace: workspace,
                    remoteViews: [SurfaceRemoteView(
                        tabID: surface.surfaceID,
                        workspace: workspace,
                        name: nil,
                        index: index,
                        focused: surface.isFocused
                    )],
                    port: nil,
                    url: nil
                ))
            }
        }
        return resources
    }

    private func lifecycle(isReady: Bool) -> SurfaceLifecycle {
        guard isLive else { return .unavailable }
        return isReady ? .running : .launching
    }

    static func agentBadge(source: String?, state: String?) -> SurfaceAgentBadge? {
        let trimmedState = state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedState.isEmpty || !trimmedSource.isEmpty else { return nil }
        return SurfaceAgentBadge(state: trimmedState, source: trimmedSource.isEmpty ? nil : trimmedSource)
    }
}
