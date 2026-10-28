/// What a crowded tab strip does (cmux.json `tabs.overflow`; cx-kp9b4, Lawrence 2026-10-15: "support
/// scrolling tabs and bigger tabs min width"). `shrink` (the default, Chrome's) narrows every tab to
/// the minimum widths and only then scrolls; `scroll` keeps tabs at a comfortable width
/// (`TabStripMetrics.scrollTabMinWidth`) and scrolls sooner.
public nonisolated enum TabOverflow: String, Hashable, Sendable, CaseIterable {
    case shrink
    case scroll
}
