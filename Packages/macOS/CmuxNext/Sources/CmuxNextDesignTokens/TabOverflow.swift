/// What a crowded tab strip does (cmux.json `tabs.overflow`; cx-kp9b4, Lawrence 2026-10-15: "support
/// scrolling tabs and bigger tabs min width"). `shrink` (the default, Chrome's) narrows every tab to
/// the minimum widths and only then scrolls; `scroll` keeps tabs at a comfortable width
/// (`TabStripMetrics.scrollTabMinWidth`) and scrolls sooner.
public nonisolated enum TabOverflow: String, Hashable, Sendable, CaseIterable {
    case shrink
    case scroll
}

/// Settings > Experimental, `experiments.tabBarStyle` (taste build 3, 2026-11-19): how the horizontal strip draws its
/// tabs. `off` (the default) is the shipped look. `glass` sets the tabs in one glass capsule with the selected tab a
/// lighter inner pill and the + its own round glass button; `fused` joins the selected tab into the content sheet
/// below while the others sit flat on the bar; `underline` draws plain labels on a hairline, the selected one bold
/// over a 2 pt rule.
public nonisolated enum TabBarStyleExperiment: String, Hashable, Sendable, CaseIterable {
    case off
    case glass
    case fused
    case underline
}

/// Settings > Experimental, `experiments.tabOverflow` (taste build 14, 2026-11-19): what a strip too narrow for its
/// tabs does. `off` (the default) is `tabs.overflow`'s shrink or scroll. Every other arm keeps tabs at one fixed
/// width, shows the close x on the hovered and the selected tab, and scrolls the selected tab into view:
/// `chevrons` scrolls under edge fades with a chevron at each hidden edge; `moreMenu` drops the tabs that do not fit
/// into a More menu at the end (the selected tab always stays); `allTabs` fades the clipped edge under a pinned
/// All Tabs pill that lists every tab.
public nonisolated enum TabOverflowExperiment: String, Hashable, Sendable, CaseIterable {
    case off
    case chevrons
    case moreMenu
    case allTabs
}
