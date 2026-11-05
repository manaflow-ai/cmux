public import CmuxNextDesignTokens

/// Debug Settings of a terminal while a person drags a divider or edge of its pane (DEV and NIGHTLY; Release and RC
/// never activate the store, so they keep the defaults). Labels are English developer text, as for every Debug
/// Settings section (`TunableSection`).
public nonisolated struct TerminalDragTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "terminalDrag", title: "Terminal Drag", symbol: "rectangle.split.2x1", order: 51)

    /// Off (the default since cmux-ad m19, 2026-11-05: perf paths ship on, no switches): when on, through a divider
    /// drag the terminal keeps its surface size and its text, clipped where the
    /// pane is narrower and beside the terminal background where it is wider, and reflows once when the drag lands
    /// (RESIZE VIDEOS A3: the text wrapped again on every drag frame). Off: the terminal draws its text reflowed to the
    /// pane on every drag frame (the PTY still resizes once, at the landing).
    public static let holdsSurfaceDuringDrag = Tunable<Bool>.toggle(
        "terminalDrag.holdSurface", section, "Hold terminal text during a divider drag",
        help: "While a divider is dragged, each terminal keeps its size and text (clipped or padded) and reflows once when the drag lands. Off: the text reflows to the pane on every frame of the drag.",
        default: false, code: "TerminalDragTunables.holdsSurfaceDuringDrag")

    /// On (the default, cmux-ad m18): a resized terminal's view takes its new bounds at once, and the window's commit
    /// shows the frame Ghostty drew at that size with them when it is drawn by that commit; one drawn later shows in the
    /// first commit after it (a late landing, counted; nothing keeps an old size). In a key resize the terminal follows its
    /// pane in every frame and its text is re-wrapped at each frame's size, whatever this switch says. Off (the kill
    /// switch): Ghostty's renderer shows each size's frame on its own, its display pass waiting up to 4 ms for it. Read on
    /// every layout, so one build films both.
    public static let framesOwnedByCommit = Tunable<Bool>.toggle(
        "motion.frameOwner.terminals", section, "Terminal frame and size in one commit",
        help: "A resized terminal takes its new size at once, and the window shows the frame drawn at that size in the same commit when it is ready, else in the next one. Off: Ghostty's renderer shows each new size's frame on its own.",
        default: true, code: "TerminalDragTunables.framesOwnedByCommit")

    public static var all: [TunableDescriptor] { [holdsSurfaceDuringDrag.descriptor, framesOwnedByCommit.descriptor] }
}
