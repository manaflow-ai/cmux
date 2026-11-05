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
        default: false, code: "TerminalDragTunables.holdsSurfaceDuringDrag")

    /// Off (the default): a resized terminal's view takes its new bounds at once and Ghostty's frame of that size
    /// lands 1-4 refreshes later (FRAME OWNER REFACTOR P2), and a key resize holds the surface at one size per press.
    /// On: ready-or-keep (stage S4): in every commit a terminal's bounds and its pixels change together, or both keep
    /// their last size, and in a key resize the terminal shows its pane's size in every frame while its PTY gets one
    /// grid per press (cmux-ad m6). It turns on by default when a held key resize with many terminals drops no more
    /// refreshes with it on than off (each moving terminal costs one new IOSurface and one main wake per frame until
    /// the Ghostty fork's coalesced frame-ready wake and render-target slack land). Read on every layout, so one build
    /// films both.
    public static let framesOwnedByCommit = Tunable<Bool>.toggle(
        "motion.frameOwner.terminals", section, "Terminal frame and size in one commit",
        help: "A resized terminal shows its new size only in the commit that has its frame drawn at that size; until then it keeps its last size and frame. In a key resize the terminal follows its pane in every frame, and its program gets one size per press. Off: the size changes at once and the frame comes 1-4 refreshes later, and a key resize keeps one terminal size per press.",
        default: true, code: "TerminalDragTunables.framesOwnedByCommit")

    public static var all: [TunableDescriptor] { [holdsSurfaceDuringDrag.descriptor, framesOwnedByCommit.descriptor] }
}
