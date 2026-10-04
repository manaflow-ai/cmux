/// The surface declarations of every catalog action
/// (plans/cmux-next/actions.md), applied to the descriptors after the
/// domain catalogs build them. Kept apart from `ActionCatalog` so the
/// domain files stay about what an action does; the descriptor carries
/// the result in `surfacePlan`. A descriptor that declares a `surfacePlan`
/// itself keeps every part it declared.
nonisolated enum ActionSurfaceCatalog {
    static func apply(to descriptors: [ActionDescriptor]) -> [ActionDescriptor] {
        descriptors.map { descriptor in
            var descriptor = descriptor
            let id = descriptor.id
            var plan = descriptor.surfacePlan
            if plan.contextMenus.isEmpty, plan.contextMenuExemption == nil {
                plan.contextMenus = placements[id] ?? []
                if plan.contextMenus.isEmpty { plan.contextMenuExemption = contextMenuExemption[id] }
            }
            if plan.cli == nil {
                plan.cli = cliNamed.contains(id) ? .offered : cliExemption[id].map(SurfaceDecision.exempt)
            }
            if plan.mcpExemption == nil { plan.mcpExemption = mcpExemption[id] }
            if plan.palette.isOffered, let reason = paletteExemption[id] { plan.palette = .exempt(reason) }
            descriptor.surfacePlan = plan
            return descriptor
        }
    }

    /// One placement row (`ActionSurfaceCatalog+Menus.swift`).
    static func p(_ context: ActionMenuContext, _ group: MenuGroup, _ rank: Int, _ style: MenuPlacementStyle = .item,
                  in parent: ActionID? = nil, folder: MenuFolder? = nil) -> ContextMenuPlacement {
        ContextMenuPlacement(context, group, rank, style: style, parent: parent, folder: folder)
    }

    /// Inverts a reason-to-actions table. An id listed under two reasons
    /// keeps one of them; `ActionSurfaceParityTests` rejects such a table.
    static func byReason(_ table: [SurfaceExemption: [ActionID]]) -> [ActionID: SurfaceExemption] {
        var result: [ActionID: SurfaceExemption] = [:]
        for reason in SurfaceExemption.allCases {
            for id in table[reason] ?? [] where result[id] == nil { result[id] = reason }
        }
        return result
    }
}
