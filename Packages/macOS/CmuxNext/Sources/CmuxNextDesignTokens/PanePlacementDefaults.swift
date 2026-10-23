/// cmux.json `layout.newPanePlacement`: where a person's new terminal (and
/// browser, with `layout.tileBrowsers`) opens. `tab` (the default) opens a
/// tab in the focused pane. `split` places a new pane like New Pane (Auto
/// Layout): the largest scrolling pane splits along its longer side
/// (Zellij's new pane). A docked column never splits.
public nonisolated enum NewPanePlacement: String, Hashable, Sendable, CaseIterable {
    case tab, split
}
