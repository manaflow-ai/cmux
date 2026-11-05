public import CmuxNextDesign

/// How far a sidebar change's motion reaches (Debug Settings `sidebar.changeMotion`,
/// https://github.com/manaflow-ai/cmux/issues/34264: Cmd-Shift-T animated the whole sidebar instead of only the row it
/// reopened). The rule: no change animates more of the sidebar than the rows it changes. A row that only shifts because
/// another row came, went, moved, folded or changed height takes its new slot at once; a row that comes in (a new or
/// reopened workspace, an expanded group's members) fades in at its own slot, and a row that leaves goes at once, since
/// the rows below already stand in its slot. A reveal of the selection or of a row jumps rather than sliding the list.
/// A drag keeps its own motion (rows make way under the pointer). `wholeList` keeps the motion before for comparison.
public nonisolated enum SidebarChangeMotion: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// Only the rows a change touches animate (the shipped default).
    case changedRows
    /// The motion before #34264: every row a change shifts moves on the `.move` spring, a closing row closes its slot,
    /// a fold clips its members under the header, and a reveal scrolls the list on `.move`.
    case wholeList

    public var tunableTitle: String {
        switch self {
        case .changedRows: "Only changed rows"
        case .wholeList: "Whole list (before)"
        }
    }

    public static let tunable = Tunable<SidebarChangeMotion>.choice(
        "sidebar.changeMotion", .sidebar, "Change motion",
        help: "How much of the sidebar a change animates. Only changed rows: rows another change shifts take their place at once, a new or reopened row fades in at its slot, a closed row goes at once, and a reveal jumps. Whole list: the rows a change shifts slide, closing rows close their slot, and a reveal scrolls.",
        default: .changedRows, code: "SidebarChangeMotion.tunable")

    /// Whether this change motion animates only the rows a change touches.
    public static var movesOnlyChangedRows: Bool { tunable.value == .changedRows }
}
