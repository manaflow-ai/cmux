import CmuxNextDaemon
import CmuxNextDesign
import CoreGraphics

/// The workspaces one window shows side by side (Debug Settings `sidebar.multiView`, Leo 2026-10-21 item D): a
/// split tree whose leaves are workspaces. A sidebar row dropped on a pane edge of the shown workspace goes on
/// that side of it (`placing`); a workspace that closes or leaves the window leaves the tree (`pruned`). Two
/// leaves at least: one workspace alone is the single view, which `WindowState.viewSet` stores as nil.
nonisolated indirect enum WorkspaceViewSet: Hashable, Sendable {
    case workspace(String)
    /// `stacked`: `first` above `second`; else `first` left of `second`. Each takes half.
    case split(stacked: Bool, first: WorkspaceViewSet, second: WorkspaceViewSet)

    /// The workspaces, left to right and top to bottom.
    var ids: [String] {
        switch self {
        case let .workspace(id): [id]
        case let .split(_, first, second): first.ids + second.ids
        }
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// `id` on `edge`'s side of `target`, which keeps the other half; an `id` already shown moves there. Nil when
    /// `target` is not shown or is `id`.
    func placing(_ id: String, beside target: String, edge: TabDropEdge) -> WorkspaceViewSet? {
        guard id != target, contains(target), let rest = pruned(keeping: { $0 != id }) else { return nil }
        return rest.replacing(target) { old in
            let new = WorkspaceViewSet.workspace(id)
            switch edge {
            case .left: return .split(stacked: false, first: new, second: old)
            case .right: return .split(stacked: false, first: old, second: new)
            case .top: return .split(stacked: true, first: new, second: old)
            case .bottom: return .split(stacked: true, first: old, second: new)
            }
        }
    }

    /// The tree without the workspaces `keeping` refuses: a split left with one side becomes that side. Nil when
    /// none is left.
    func pruned(keeping: (String) -> Bool) -> WorkspaceViewSet? {
        switch self {
        case let .workspace(id):
            return keeping(id) ? self : nil
        case let .split(stacked, first, second):
            switch (first.pruned(keeping: keeping), second.pruned(keeping: keeping)) {
            case let (a?, b?): return .split(stacked: stacked, first: a, second: b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            case (nil, nil): return nil
            }
        }
    }

    private func replacing(_ target: String, with make: (WorkspaceViewSet) -> WorkspaceViewSet) -> WorkspaceViewSet {
        switch self {
        case let .workspace(id): id == target ? make(self) : self
        case let .split(stacked, first, second):
            .split(stacked: stacked, first: first.replacing(target, with: make), second: second.replacing(target, with: make))
        }
    }

    /// Each workspace's part of `rect` (y down: `minY` is the top), halves split by `gap` points.
    func frames(in rect: CGRect, gap: CGFloat) -> [(id: String, frame: CGRect)] {
        switch self {
        case let .workspace(id):
            return [(id, rect)]
        case let .split(stacked, first, second):
            let half = ((stacked ? rect.height : rect.width) - gap) / 2
            let (a, b) = stacked
                ? (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: half),
                   CGRect(x: rect.minX, y: rect.minY + half + gap, width: rect.width, height: rect.height - half - gap))
                : (CGRect(x: rect.minX, y: rect.minY, width: half, height: rect.height),
                   CGRect(x: rect.minX + half + gap, y: rect.minY, width: rect.width - half - gap, height: rect.height))
            return first.frames(in: a, gap: gap) + second.frames(in: b, gap: gap)
        }
    }

    /// The half of `rect` a workspace dropped on `edge` takes (y down), for the drag ghost's landing.
    static func half(of rect: CGRect, at edge: TabDropEdge, yDown: Bool = true) -> CGRect {
        let (w, h) = (rect.width / 2, rect.height / 2)
        switch edge {
        case .left: return CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
        case .right: return CGRect(x: rect.midX, y: rect.minY, width: w, height: rect.height)
        case .top: return CGRect(x: rect.minX, y: yDown ? rect.minY : rect.midY, width: rect.width, height: h)
        case .bottom: return CGRect(x: rect.minX, y: yDown ? rect.midY : rect.minY, width: rect.width, height: h)
        }
    }
}

extension WorkspaceViewSet {
    /// The window record's shape (`WindowRecord.multiView`); nil for a tree with no workspace.
    init?(record: WindowViewLayout) {
        if let key = record.workspace {
            self = .workspace(key.rawValue)
            return
        }
        guard let parts = record.parts, parts.count == 2, let first = WorkspaceViewSet(record: parts[0]),
              let second = WorkspaceViewSet(record: parts[1]) else { return nil }
        self = .split(stacked: record.axis == WindowViewLayout.stacked, first: first, second: second)
    }

    var record: WindowViewLayout {
        switch self {
        case let .workspace(id): WindowViewLayout(workspace: WorkspaceKey(rawValue: id))
        case let .split(stacked, first, second):
            WindowViewLayout(axis: stacked ? WindowViewLayout.stacked : WindowViewLayout.sideBySide, parts: [first.record, second.record])
        }
    }
}
