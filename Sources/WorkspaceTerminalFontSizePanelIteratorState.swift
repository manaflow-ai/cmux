import CmuxTerminal
import Foundation

extension WorkspaceTerminalFontSizePanelDiscovery {
    @MainActor
    struct IteratorState {
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
}
