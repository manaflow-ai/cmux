/// `workspaceColors.indicatorStyle` (#25653): how a workspace's color shows on its sidebar row.
/// `dot` (the default) draws the color as the row's swatch before its name, `leftRail` as a bar
/// down the row's leading edge, `fill` as the whole row's background, so a colored workspace
/// (one an agent marked ready for review, say) reads at a glance. A symbol or emoji icon keeps
/// its tint in every style.
public nonisolated enum WorkspaceColorIndicatorStyle: String, Hashable, Sendable, CaseIterable {
    case dot
    case leftRail
    case fill

    /// The value cmux.json names, or classic's `solidFill` for `fill`, so a classic config carries over.
    public init?(setting value: String) {
        if value == "solidFill" { self = .fill } else { self.init(rawValue: value) }
    }
}
