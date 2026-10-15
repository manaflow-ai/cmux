import QuartzCore

/// Row content patches (an agent's working/idle status, progress, a title) that arrive while a drag, its
/// settle or its card's landing runs. The list keeps drawing each patched row as it was when the hold began,
/// so no row changes height under the drag and no tick reload retargets the rows' springs (hitch16: 50
/// ticking terminals at 1000 workspaces bent the rows 4-16.5 pt at the drop's revision change). When the
/// card is gone, every held patch applies at once, in one transaction.
struct SidebarRowHold {
    /// The patched rows as the list showed them when their first patch was held.
    var shown: [WorkspaceID: SidebarWorkspace] = [:]
    /// The latest patch of each held row (what `SidebarModel` stores now).
    var pending: [WorkspaceID: SidebarWorkspace] = [:]

    var isEmpty: Bool { pending.isEmpty }

    /// `sections` with each held row as it was shown. A row that changed since its patch in another way (a
    /// structural update rewrote it) is not the patch's value any more: it shows as the model has it. Each
    /// listed copy keeps its own row state and machine (a saved stale row beside the live one).
    func apply(to sections: [SidebarSection]) -> [SidebarSection] {
        guard !shown.isEmpty else { return sections }
        func held(_ ws: SidebarWorkspace) -> SidebarWorkspace {
            guard var old = shown[ws.id], var patch = pending[ws.id] else { return ws }
            patch.rowState = ws.rowState
            patch.machineID = ws.machineID
            guard patch == ws else { return ws }
            old.rowState = ws.rowState
            old.machineID = ws.machineID
            return old
        }
        var sections = sections
        for s in sections.indices {
            for n in sections[s].nodes.indices {
                switch sections[s].nodes[n] {
                case let .workspace(ws):
                    let shownWS = held(ws)
                    if shownWS != ws { sections[s].nodes[n] = .workspace(shownWS) }
                case var .group(group):
                    guard group.workspaces.contains(where: { shown[$0.id] != nil }) else { continue }
                    group.workspaces = group.workspaces.map(held)
                    sections[s].nodes[n] = .group(group)
                case .item:
                    continue
                }
            }
        }
        return sections
    }
}

extension SidebarListView {
    /// A drag, its settle or its card's landing runs: row patches wait (`SidebarRowHold`). OFF: hitch17 (1000
    /// workspaces, 50 ticking terminals) had 175 and 128 jumps where hitch16 without the hold had none: at a revision
    /// change the scroll offset moved 758 pt (and 1248 pt) and the rows sprang about 970 pt. Until a release that never
    /// jumps is proven, patches apply as they come (`rowHoldEnabled`).
    var holdsRowPatches: Bool { Self.rowHoldEnabled && (drag != nil || settling != nil || landing != nil) }
    static let rowHoldEnabled = false

    /// The sections the list lays out: the model's, with the held rows as they were shown. The drag's hit
    /// geometry and the shown rows use the same ones, so a held height never maps a drop to the wrong slot.
    var listSections: [SidebarSection] { rowHold.isEmpty ? model.sections : rowHold.apply(to: model.sections) }

    /// Holds `patched` until the drag's card is gone.
    /// (Counted in `.rowPatches` when they apply.)
    func holdRowPatches(_ patched: [SidebarWorkspace]) {
        for ws in patched {
            if rowHold.shown[ws.id] == nil, let old = workspaces[ws.id] { rowHold.shown[ws.id] = old }
            rowHold.pending[ws.id] = ws
        }
    }

    /// The drag's card is gone: the held patches apply in one transaction (a height change reloads the rows
    /// on their spring). A drag that started meanwhile keeps holding them.
    /// `extra`: patches that arrived now, applied with the held ones (the newer one of a row wins).
    func releaseRowHold(adding extra: [SidebarWorkspace] = []) {
        guard !holdsRowPatches, !rowHold.isEmpty else { return }
        var pending = rowHold.pending
        for ws in extra { pending[ws.id] = ws }
        rowHold = SidebarRowHold()
        CATransaction.begin()
        defer { CATransaction.commit() }
        patchRows(Array(pending.values))
    }
}
