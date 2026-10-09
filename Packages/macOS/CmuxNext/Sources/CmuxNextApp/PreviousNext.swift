/// Previous / Next (Leo 2026-10-09, rapid switching): what the
/// browser-style keys step from the window's keyboard focus.
enum PreviousNext {
    enum Scope: Equatable {
        /// The focused pane's tabs, wrapping inside the pane.
        case paneTabs
        /// The sidebar rows, in sidebar order.
        case sidebarRows
    }

    nonisolated static func scope(for focus: FocusState.Resolved, paneTabs: Int) -> Scope {
        .paneTabs
    }
}
