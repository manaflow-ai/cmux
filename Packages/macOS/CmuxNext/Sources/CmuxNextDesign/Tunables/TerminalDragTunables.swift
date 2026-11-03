public import CmuxNextDesignTokens

/// Debug Settings of a terminal while a person drags a divider or edge of its pane (DEV and NIGHTLY; Release and RC
/// never activate the store, so they keep the defaults). Labels are English developer text, as for every Debug
/// Settings section (`TunableSection`).
public nonisolated struct TerminalDragTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "terminalDrag", title: "Terminal Drag", symbol: "rectangle.split.2x1", order: 51)

    /// On (the default): through a divider drag the terminal keeps its surface size and its text, clipped where the
    /// pane is narrower and beside the terminal background where it is wider, and reflows once when the drag lands
    /// (RESIZE VIDEOS A3: the text wrapped again on every drag frame). Off: the terminal draws its text reflowed to the
    /// pane on every drag frame (the PTY still resizes once, at the landing).
    public static let holdsSurfaceDuringDrag = Tunable<Bool>.toggle(
        "terminalDrag.holdSurface", section, "Hold terminal text during a divider drag",
        help: "While a divider is dragged, each terminal keeps its size and text (clipped or padded) and reflows once when the drag lands. Off: the text reflows to the pane on every frame of the drag.",
        default: true, code: "TerminalDragTunables.holdsSurfaceDuringDrag")

    /// Off (the default): a resized terminal's view takes its new bounds at once and Ghostty's frame of that size
    /// lands 1-4 refreshes later (FRAME OWNER REFACTOR P2). On: ready-or-keep (stage S4): in every commit a
    /// terminal's bounds and its pixels change together, or both keep their last size. Read on every layout and
    /// every pre-commit pass, so one build films both.
    public static let framesOwnedByCommit = Tunable<Bool>.toggle(
        "motion.frameOwner.terminals", section, "Terminal frame and size in one commit",
        help: "A resized terminal shows its new size only in the commit that has its frame drawn at that size; until then it keeps its last size and frame. Off: the size changes at once and the frame comes 1-4 refreshes later.",
        default: false, code: "TerminalDragTunables.framesOwnedByCommit")

    public static var all: [TunableDescriptor] { [holdsSurfaceDuringDrag.descriptor, framesOwnedByCommit.descriptor] }
}
