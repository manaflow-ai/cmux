import Foundation

/// Immutable main-actor workspace state captured when Save Workspace as Layout is invoked.
/// Foreground process discovery may later fill only the identified terminal command slots.
nonisolated struct WorkspaceConfigActionCapture: Sendable {
    struct TerminalCommandTarget: Equatable, Sendable {
        let surfaceOrdinal: Int
        let ttyDevice: Int64
    }

    let snapshot: WorkspaceConfigActionSnapshot
    let initialName: String
    let terminalCommandTargets: [TerminalCommandTarget]

    var ttyDevices: Set<Int64> {
        Set(terminalCommandTargets.map(\.ttyDevice))
    }

    func enrichedSnapshot(liveCommandsByTTY: [Int64: String]) -> WorkspaceConfigActionSnapshot {
        var enriched = snapshot
        if let layout = enriched.definition.layout {
            var surfaceOrdinal = 0
            var targetBySurfaceOrdinal: [Int: Int64] = [:]
            targetBySurfaceOrdinal.reserveCapacity(terminalCommandTargets.count)
            for target in terminalCommandTargets {
                targetBySurfaceOrdinal[target.surfaceOrdinal] = target.ttyDevice
            }
            enriched.definition.layout = enrichingTerminalCommands(
                in: layout,
                targetBySurfaceOrdinal: targetBySurfaceOrdinal,
                liveCommandsByTTY: liveCommandsByTTY,
                surfaceOrdinal: &surfaceOrdinal
            )
        }
        enriched.definition.layout = simplifiedLayout(enriched.definition.layout)
        return enriched
    }

    private func enrichingTerminalCommands(
        in node: CmuxLayoutNode,
        targetBySurfaceOrdinal: [Int: Int64],
        liveCommandsByTTY: [Int64: String],
        surfaceOrdinal: inout Int
    ) -> CmuxLayoutNode {
        switch node {
        case .pane(var pane):
            for index in pane.surfaces.indices {
                let ordinal = surfaceOrdinal
                surfaceOrdinal += 1
                guard let ttyDevice = targetBySurfaceOrdinal[ordinal],
                      let command = liveCommandsByTTY[ttyDevice] else { continue }
                pane.surfaces[index].command = command
            }
            return .pane(pane)
        case .split(var split):
            split.children = split.children.map { child in
                enrichingTerminalCommands(
                    in: child,
                    targetBySurfaceOrdinal: targetBySurfaceOrdinal,
                    liveCommandsByTTY: liveCommandsByTTY,
                    surfaceOrdinal: &surfaceOrdinal
                )
            }
            return .split(split)
        }
    }

    /// A single plain terminal carries no information beyond the workspace itself.
    private func simplifiedLayout(_ layout: CmuxLayoutNode?) -> CmuxLayoutNode? {
        guard case .pane(let pane)? = layout, pane.surfaces.count == 1 else { return layout }
        let surface = pane.surfaces[0]
        let isPlainTerminal = surface.type == .terminal
            && surface.command == nil
            && surface.name == nil
            && surface.cwd == nil
            && surface.url == nil
        return isPlainTerminal ? nil : layout
    }
}
