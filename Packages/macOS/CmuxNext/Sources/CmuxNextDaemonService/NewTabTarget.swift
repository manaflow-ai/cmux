public import CmuxNextDaemon

/// A new tab's slot other than the end of its pane (the end is nil: the daemon appends).
public enum NewTabTarget: Equatable {
    /// Right after this tab, after its tab group; `joins`: in its group (a duplicate, as Chrome's).
    case after(TabModel, joins: Bool = false)
    /// First after the pinned tabs of the pane this tab is in.
    case start(TabModel)

    /// The tab whose group the new tab joins.
    public var joins: TabModel? { if case .after(let tab, true) = self { tab } else { nil } }
    /// The tab that names the pane.
    public var anchor: TabModel { switch self { case .after(let tab, _), .start(let tab): tab } }

    /// Two slots are the same when they name the same tab the same way.
    public static func == (lhs: NewTabTarget, rhs: NewTabTarget) -> Bool {
        switch (lhs, rhs) {
        case (.after(let a, let x), .after(let b, let y)): return a === b && x == y
        case (.start(let a), .start(let b)): return a === b
        default: return false
        }
    }
}
