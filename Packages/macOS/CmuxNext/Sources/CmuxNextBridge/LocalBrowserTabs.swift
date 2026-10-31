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

    /// Whether `other` keeps tabs under one of `panes` that has tabs here (pane ids can repeat across machines).
    public func collides(panes ids: Set<String>, with other: LocalBrowserTabs) -> Bool {
        other !== self && all.contains { ids.contains($0.pane) && !other[$0.pane].isEmpty }
    }

    /// Moves the tabs of `panes` to `other` (their workspace moved to another window).
    public func move(panes ids: Set<String>, to other: LocalBrowserTabs) {
        guard other !== self else { return }
        for (pane, tabs) in all where ids.contains(pane) {
            other[pane] += tabs
            self[pane] = []
        }
    }
}
