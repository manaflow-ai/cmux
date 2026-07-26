import Foundation
import CmuxTerminal

/// Lazily discovers terminal identities under a bounded coordinator visit.
///
/// Iterator storage is disposable because Swift dictionary iterators retain
/// every backing value. Completed identity checkpoints survive disposal.
@MainActor
struct WorkspaceTerminalFontSizePanelDiscovery {
    private enum Scope {
        case workspace
        case windowDock
    }

    enum Origin {
        case workspace
        case workspaceDock
        case remoteMirror(mirrorId: UUID, paneId: Int)
        case windowDock
    }

    struct Candidate {
        let panelId: UUID
        let origin: Origin

        @MainActor
        func mountedTerminalPanel(
            in workspace: Workspace?,
            windowDock: DockSplitStore?
        ) -> TerminalPanel? {
            switch origin {
            case .workspace:
                return workspace?.panels[panelId] as? TerminalPanel
            case .workspaceDock:
                return workspace?._dockSplit?.panels[panelId]
                    as? TerminalPanel
            case .remoteMirror(let mirrorId, let paneId):
                guard let panel = workspace?
                    .remoteTmuxWindowMirror(forPanelId: mirrorId)?
                    .panelsByPaneId[paneId],
                      panel.id == panelId else {
                    return nil
                }
                return panel
            case .windowDock:
                return windowDock?.panels[panelId] as? TerminalPanel
            }
        }
    }

    enum Visit {
        case candidate(Candidate)
        case nonTerminal
    }

    private enum EntryKey: Hashable {
        case workspace(UUID)
        case workspaceDock(UUID)
        case remoteMirror(UUID)
        case remotePane(
            mirrorId: UUID,
            paneId: Int,
            panelId: UUID
        )
        case windowDock(UUID)
    }

    @MainActor
    private struct IteratorState {
        private enum Phase {
            case workspace
            case workspaceDock
            case remoteMirrors
            case windowDock
            case finished
        }

        private var phase: Phase
        private var workspacePanels:
            Dictionary<UUID, any Panel>.Iterator?
        private var workspaceDockPanels:
            Dictionary<UUID, any Panel>.Iterator?
        private var remoteMirrors:
            Dictionary<UUID, RemoteTmuxWindowMirror>.Iterator?
        private var remoteMirrorPanels:
            Dictionary<Int, TerminalPanel>.Iterator?
        private var remoteMirrorId: UUID?
        private var windowDockPanels:
            Dictionary<UUID, any Panel>.Iterator?

        init(workspace: Workspace) {
            phase = .workspace
            workspacePanels = workspace.panels.makeIterator()
            workspaceDockPanels =
                workspace._dockSplit?.panels.makeIterator()
            remoteMirrors =
                workspace.remoteTmuxWindowMirrors.makeIterator()
            remoteMirrorPanels = nil
            remoteMirrorId = nil
            windowDockPanels = nil
        }

        init(windowDock: DockSplitStore?) {
            phase = .windowDock
            workspacePanels = nil
            workspaceDockPanels = nil
            remoteMirrors = nil
            remoteMirrorPanels = nil
            remoteMirrorId = nil
            windowDockPanels = windowDock?.panels.makeIterator()
        }

        mutating func nextEntry()
            -> (key: EntryKey, visit: Visit)? {
            while true {
                switch phase {
                case .workspace:
                    if let (panelId, panel) =
                            workspacePanels?.next() {
                        let visit: Visit =
                            panel is TerminalPanel
                            ? .candidate(
                                Candidate(
                                    panelId: panelId,
                                    origin: .workspace
                                )
                            )
                            : .nonTerminal
                        return (.workspace(panelId), visit)
                    }
                    workspacePanels = nil
                    phase = .workspaceDock

                case .workspaceDock:
                    if let (panelId, panel) =
                            workspaceDockPanels?.next() {
                        let visit: Visit =
                            panel is TerminalPanel
                            ? .candidate(
                                Candidate(
                                    panelId: panelId,
                                    origin: .workspaceDock
                                )
                            )
                            : .nonTerminal
                        return (.workspaceDock(panelId), visit)
                    }
                    workspaceDockPanels = nil
                    phase = .remoteMirrors

                case .remoteMirrors:
                    if let (paneId, panel) =
                            remoteMirrorPanels?.next(),
                       let remoteMirrorId {
                        return (
                            .remotePane(
                                mirrorId: remoteMirrorId,
                                paneId: paneId,
                                panelId: panel.id
                            ),
                            .candidate(
                                Candidate(
                                    panelId: panel.id,
                                    origin: .remoteMirror(
                                        mirrorId: remoteMirrorId,
                                        paneId: paneId
                                    )
                                )
                            )
                        )
                    }
                    remoteMirrorPanels = nil
                    remoteMirrorId = nil
                    if let (mirrorId, mirror) =
                            remoteMirrors?.next() {
                        remoteMirrorId = mirrorId
                        remoteMirrorPanels =
                            mirror.panelsByPaneId.makeIterator()
                        return (
                            .remoteMirror(mirrorId),
                            .nonTerminal
                        )
                    }
                    remoteMirrors = nil
                    phase = .windowDock

                case .windowDock:
                    if let (panelId, panel) =
                            windowDockPanels?.next() {
                        let visit: Visit =
                            panel is TerminalPanel
                            ? .candidate(
                                Candidate(
                                    panelId: panelId,
                                    origin: .windowDock
                                )
                            )
                            : .nonTerminal
                        return (.windowDock(panelId), visit)
                    }
                    windowDockPanels = nil
                    phase = .finished

                case .finished:
                    return nil
                }
            }
        }
    }

    private let scope: Scope
    private var iteratorState: IteratorState?
    private var completedEntryKeys: Set<EntryKey> = []
    private var isFinished = false
#if DEBUG
    let debugConstructionVisitCount = 0
#endif

    init(workspace _: Workspace) {
        scope = .workspace
    }

    init(windowDock _: DockSplitStore?) {
        scope = .windowDock
    }

    mutating func nextVisit(
        in workspace: Workspace?,
        windowDock: DockSplitStore?
    ) -> Visit? {
        guard !isFinished else { return nil }
        if iteratorState == nil {
            switch scope {
            case .workspace:
                guard let workspace else {
                    isFinished = true
                    return nil
                }
                iteratorState = IteratorState(
                    workspace: workspace
                )
            case .windowDock:
                iteratorState = IteratorState(
                    windowDock: windowDock
                )
            }
        }

        guard let entry = iteratorState?.nextEntry() else {
            iteratorState = nil
            isFinished = true
            return nil
        }
        guard completedEntryKeys.insert(entry.key).inserted else {
            return .nonTerminal
        }
        return entry.visit
    }

    mutating func discardRetainedPanelStorage() {
        iteratorState = nil
    }
}
