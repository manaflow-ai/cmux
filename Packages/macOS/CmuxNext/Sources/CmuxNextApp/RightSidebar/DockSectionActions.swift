/// What the Dock section's rows and buttons can ask for.
struct DockSectionActions {
    /// Focuses a pane (by its key).
    let focus: @MainActor (String) -> Void
    /// Undocks a column (by its id).
    let undock: @MainActor (String) -> Void
    /// Docks the focused pane's column.
    let dockFocused: @MainActor () -> Void
}
