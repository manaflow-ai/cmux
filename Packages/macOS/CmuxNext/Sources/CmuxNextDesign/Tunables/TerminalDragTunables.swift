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
    /// terminal's bounds and its pixels change together, or both keep their last size. Read on every layout, so one
    /// build films both.
    public static let framesOwnedByCommit = Tunable<Bool>.toggle(
        "motion.frameOwner.terminals", section, "Terminal frame and size in one commit",
        help: "A resized terminal shows its new size only in the commit that has its frame drawn at that size; until then it keeps its last size and frame. Off: the size changes at once and the frame comes 1-4 refreshes later.",
        default: false, code: "TerminalDragTunables.framesOwnedByCommit")

    /// SCRATCH, never merged (S4 defect (a) film arms): with the frame owner on, Ghostty presents host sizes itself
    /// (renderer mode) instead of leaving them to cmux. Read when the frame owner turns on.
    public static let framesOwnedByCommitRendererMode = Tunable<Bool>.toggle(
        "motion.frameOwner.terminalsRendererMode", section, "S4 arm: Ghostty renderer mode",
        help: "Scratch film arm: with the frame owner on, Ghostty keeps presenting host sizes itself.",
        default: false, code: "TerminalDragTunables.framesOwnedByCommitRendererMode")

    /// SCRATCH, never merged (S4 defect (a) film arms): with the frame owner on, place() sets the frame at once, as with
    /// it off (no wanted frame, no request). Read on every layout.
    public static let framesOwnedByCommitDirectPlace = Tunable<Bool>.toggle(
        "motion.frameOwner.terminalsDirectPlace", section, "S4 arm: place at once",
        help: "Scratch film arm: with the frame owner on, the terminal takes its frame at once.",
        default: false, code: "TerminalDragTunables.framesOwnedByCommitDirectPlace")

    public static var all: [TunableDescriptor] {
        [holdsSurfaceDuringDrag.descriptor, framesOwnedByCommit.descriptor, framesOwnedByCommitRendererMode.descriptor,
         framesOwnedByCommitDirectPlace.descriptor]
    }
}
