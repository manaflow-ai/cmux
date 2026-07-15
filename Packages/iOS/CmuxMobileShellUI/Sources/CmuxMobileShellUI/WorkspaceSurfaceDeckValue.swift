import CmuxMobileShellModel

/// Immutable presentation data for the workspace pane-and-tab deck.
struct WorkspaceSurfaceDeckValue: Equatable {
    struct NormalizedRect: Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    struct Pane: Identifiable, Equatable {
        let id: MobileWorkspacePanePreview.ID
        /// `nil` for the synthetic single pane used with legacy Mac hosts.
        let remoteID: MobileWorkspacePanePreview.ID?
        let index: Int
        let terminals: [MobileTerminalPreview]
        let selectedTerminalID: MobileTerminalPreview.ID?
        let isMacFocused: Bool
        let frame: NormalizedRect

        var selectedTerminal: MobileTerminalPreview? {
            terminals.first { $0.id == selectedTerminalID } ?? terminals.first
        }
    }

    let panes: [Pane]
    let activePaneID: MobileWorkspacePanePreview.ID?
    let selectedTerminalID: MobileTerminalPreview.ID?
    let hasAuthoritativeLayout: Bool

    var activePane: Pane? {
        panes.first { $0.id == activePaneID } ?? panes.first
    }

    init(
        workspace: MobileWorkspacePreview,
        selectedTerminalID: MobileTerminalPreview.ID?,
        paneSelections: [MobileWorkspacePanePreview.ID: MobileTerminalPreview.ID] = [:]
    ) {
        self.selectedTerminalID = selectedTerminalID
        let terminalsByID = Dictionary(uniqueKeysWithValues: workspace.terminals.map { ($0.id, $0) })

        guard let layout = workspace.paneLayout else {
            let syntheticID = MobileWorkspacePanePreview.ID(rawValue: "legacy:\(workspace.id.rawValue)")
            panes = [
                Pane(
                    id: syntheticID,
                    remoteID: nil,
                    index: 1,
                    terminals: workspace.terminals,
                    selectedTerminalID: selectedTerminalID ?? workspace.terminals.first?.id,
                    isMacFocused: true,
                    frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
                ),
            ]
            activePaneID = syntheticID
            hasAuthoritativeLayout = false
            return
        }

        var frames: [MobileWorkspacePanePreview.ID: NormalizedRect] = [:]
        Self.collectFrames(
            from: layout.root,
            in: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            into: &frames
        )
        var resolvedPanes = layout.panes.enumerated().map { offset, pane in
            let terminals = pane.terminalIDs.compactMap { terminalsByID[$0] }
            let phoneSelection = selectedTerminalID.flatMap { id in
                terminals.contains(where: { $0.id == id }) ? id : nil
            }
            let rememberedSelection = paneSelections[pane.id].flatMap { id in
                terminals.contains(where: { $0.id == id }) ? id : nil
            }
            let macSelection = pane.selectedTerminalID.flatMap { id in
                terminals.contains(where: { $0.id == id }) ? id : nil
            }
            return Pane(
                id: pane.id,
                remoteID: pane.id,
                index: offset + 1,
                terminals: terminals,
                selectedTerminalID: phoneSelection ?? rememberedSelection ?? macSelection ?? terminals.first?.id,
                isMacFocused: pane.isFocused,
                frame: frames[pane.id] ?? NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            )
        }

        // A mixed-version or malformed snapshot must never make a terminal
        // disappear. Keep unreferenced terminals in the first pane as a safe
        // compatibility fallback while retaining the authoritative tree.
        let referencedIDs = Set(resolvedPanes.flatMap { $0.terminals.map(\.id) })
        let orphanedTerminals = workspace.terminals.filter { !referencedIDs.contains($0.id) }
        if !orphanedTerminals.isEmpty, let first = resolvedPanes.first {
            let selectedOrphanID = selectedTerminalID.flatMap { selectedID in
                orphanedTerminals.contains(where: { $0.id == selectedID }) ? selectedID : nil
            }
            resolvedPanes[0] = Pane(
                id: first.id,
                remoteID: first.remoteID,
                index: first.index,
                terminals: first.terminals + orphanedTerminals,
                selectedTerminalID: selectedOrphanID ?? first.selectedTerminalID ?? orphanedTerminals.first?.id,
                isMacFocused: first.isMacFocused,
                frame: first.frame
            )
        }

        panes = resolvedPanes
        activePaneID = resolvedPanes.first(where: { pane in
            selectedTerminalID.map { selected in pane.terminals.contains(where: { $0.id == selected }) } ?? false
        })?.id
            ?? resolvedPanes.first(where: \.isMacFocused)?.id
            ?? resolvedPanes.first?.id
        hasAuthoritativeLayout = true
    }

    private static func collectFrames(
        from node: MobileWorkspacePaneLayout.Node,
        in rect: NormalizedRect,
        into frames: inout [MobileWorkspacePanePreview.ID: NormalizedRect]
    ) {
        switch node {
        case .pane(let pane):
            frames[pane.id] = rect
        case .split(let split):
            let fraction = min(max(split.fraction, 0.05), 0.95)
            switch split.axis {
            case .horizontal:
                collectFrames(
                    from: split.first,
                    in: NormalizedRect(
                        x: rect.x,
                        y: rect.y,
                        width: rect.width * fraction,
                        height: rect.height
                    ),
                    into: &frames
                )
                collectFrames(
                    from: split.second,
                    in: NormalizedRect(
                        x: rect.x + rect.width * fraction,
                        y: rect.y,
                        width: rect.width * (1 - fraction),
                        height: rect.height
                    ),
                    into: &frames
                )
            case .vertical:
                collectFrames(
                    from: split.first,
                    in: NormalizedRect(
                        x: rect.x,
                        y: rect.y,
                        width: rect.width,
                        height: rect.height * fraction
                    ),
                    into: &frames
                )
                collectFrames(
                    from: split.second,
                    in: NormalizedRect(
                        x: rect.x,
                        y: rect.y + rect.height * fraction,
                        width: rect.width,
                        height: rect.height * (1 - fraction)
                    ),
                    into: &frames
                )
            }
        }
    }
}
