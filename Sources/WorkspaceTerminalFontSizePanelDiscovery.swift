import Foundation
import CmuxTerminal

/// Lazily discovers terminal identities under a bounded coordinator visit.
///
/// Iterator storage is disposable because Swift dictionary iterators retain
/// every backing value. Completed identity checkpoints survive disposal.
@MainActor
struct WorkspaceTerminalFontSizePanelDiscovery {
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
