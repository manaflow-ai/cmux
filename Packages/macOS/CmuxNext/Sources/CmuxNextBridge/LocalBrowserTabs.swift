import CmuxNextCompat
public import Foundation

/// A browser tab that lives only in this app session because the daemon
/// lacks `frontend-browser-tabs-v1`. Not restored after relaunch.
public struct LocalBrowserTab: Hashable, Sendable {
    public static let prefix = "local-browser:"
    public let id: String
    public var url: URL?

    public static func make(url: URL?) -> LocalBrowserTab {
        LocalBrowserTab(id: prefix + UUID().uuidString.lowercased(), url: url)
    }
}

/// Session-only browser tabs per pane, keyed (`ObservedMap`): reading pane
/// X's tabs observes pane X only.
@MainActor
public final class LocalBrowserTabs {
    private let panes = ObservedMap<String, [LocalBrowserTab]>()

    public init() {}

    /// The tabs of `pane` (`PaneModel.id`).
    public subscript(pane: String) -> [LocalBrowserTab] {
        get { panes[pane] ?? [] }
        set { panes[pane] = newValue.isEmpty ? nil : newValue }
    }

    /// Every pane with tabs (reads every pane).
    public var all: [(pane: String, tabs: [LocalBrowserTab])] { panes.entries.map { ($0.key, $0.value) } }

    /// Moves the tabs of `panes` (one workspace's panes) from this window's tabs into `target`'s, as the workspace moves
    /// between windows: they are session-only and live nowhere else, so a move that left them behind would strand them,
    /// and the emptied window's close would drop them. Moves nothing and returns false when `target` already has tabs
    /// under one of those pane ids (ids repeat across machines): the workspace must not move then.
    public func move(panes ids: [String], to target: LocalBrowserTabs) -> Bool {
        guard target !== self else { return true }
        let moving = ids.filter { !self[$0].isEmpty }
        guard moving.allSatisfy({ target[$0].isEmpty }) else { return false }
        for id in moving { (target[id], self[id]) = (self[id], []) }
        return true
    }
}
