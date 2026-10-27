/// cmux.json `layout.scrollModifier`: which scroll moves the layout (the columns strip, a column's
/// rows, a scroll area, a canvas) and which goes to the pane under the pointer.
public nonisolated enum LayoutScrollModifier: String, Hashable, Sendable, CaseIterable {
    /// Command + scroll moves the layout anywhere, on both axes; a plain scroll always goes to the
    /// pane under the pointer, and moves the layout only over chrome with no pane under it (the gaps
    /// between panes, the strip scrollbar). The default (Lawrence 2026-10-24).
    case command
    /// No modifier: a sideways scroll over a columns screen moves the strip unless the pane's
    /// content scrolls sideways itself, and rows scroll over the gaps between them or with Command
    /// (the rule before `command`, rows.md V5, scroll-areas-DESIGN.md I1 to I3).
    case noModifier = "none"
}
