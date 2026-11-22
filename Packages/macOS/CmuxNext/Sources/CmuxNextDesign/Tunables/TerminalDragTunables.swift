public import CmuxNextDesignTokens

/// Debug Settings of a terminal while its pane resizes (DEV and NIGHTLY; Release and RC never activate the store, so
/// they keep the defaults). Labels are English developer text, as for every Debug Settings section (`TunableSection`).
public nonisolated struct TerminalDragTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "terminalDrag", title: "Terminal Drag", symbol: "rectangle.split.2x1", order: 51)

    /// No switch is left: cmux-ad m14 deleted the drag hold (`terminalDrag.holdSurface`), and cmux-ad m26 (T-KEYS)
    /// deleted `motion.frameOwner.terminals` and its off path (a terminal's bounds and its frame change in one commit).
    public static var all: [TunableDescriptor] { [] }
}
