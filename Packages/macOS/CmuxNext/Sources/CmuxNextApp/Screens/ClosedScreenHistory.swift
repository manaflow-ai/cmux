import CmuxNextDaemon
import Foundation

/// Recently closed screens, newest last, for Reopen Closed Screen on a
/// daemon without closed history (`DaemonClosedHistory` serves the rest). Each
/// record keeps what the screen looked like (name, color, icon, pin, group,
/// position) and the directory of its active tab. Reopening creates a new
/// screen with that metadata at the old position; terminals are not
/// reattached (a closed screen's terminals are reaped by the daemon).
@MainActor
final class ClosedScreenHistory {
    struct Record: Equatable {
        var workspaceID: String
        var index: Int
        var spec: ScreenSpec
        var cwd: String?
        /// For history lists (plans/cmux-next/history.md).
        var id = UUID().uuidString
        var closedAt = Date()
        var workspaceTitle: String?
    }

    static let capacity = 20
    private(set) var records: [Record] = []

    /// Records `screen` unless `daemon` keeps closed history itself.
    func record(_ screen: ScreenModel, in workspace: WorkspaceModel, daemon: DaemonStore) {
        guard !daemon.servesStateResources else { return }
        let pane = screen.defaultPane.flatMap(screen.pane) ?? screen.panes.first
        let tab = pane.flatMap { $0.tabs.indices.contains($0.defaultTabIndex) ? $0.tabs[$0.defaultTabIndex] : $0.tabs.first }
        let index = workspace.screens.firstIndex { $0 === screen } ?? workspace.screens.count
        let spec = ScreenSpec(name: screen.name, color: screen.color, icon: screen.icon, pinned: screen.pinned ? true : nil,
                              index: index, group: screen.group)
        records.append(Record(workspaceID: workspace.id, index: index, spec: spec, cwd: tab?.cwd, workspaceTitle: workspace.displayName))
        if records.count > Self.capacity { records.removeFirst(records.count - Self.capacity) }
    }

    /// Takes one record out (reopen from a history list).
    func take(id: String) -> Record? {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        return records.remove(at: index)
    }

    func clear(since: Date?) {
        records.removeAll { record in since.map { record.closedAt >= $0 } ?? true }
    }

    /// The newest record whose workspace `isLive`, removed from the history.
    func popLatest(isLive: (String) -> Bool) -> Record? {
        while let record = records.popLast() {
            if isLive(record.workspaceID) { return record }
        }
        return nil
    }
}
