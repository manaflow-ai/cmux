/// Inputs to the navigation reducer: keys, field edits and source batches.
nonisolated public enum PaletteNavEvent: Equatable, Sendable {
    /// Open on the root, or on `scope` above the root, with `query` typed.
    /// Any scope id opens: a page the App opens directly (an argument
    /// picker from a shortcut) need not be in the graph. Callers that take
    /// ids from outside (`palette.open`) check the graph first.
    case open(scope: PaletteScopeID?, query: String)
    /// The palette closed from outside (click elsewhere, a closing command).
    case close
    /// The field's text changed.
    case setQuery(String)
    /// Backspace with an empty field.
    case backspaceOnEmpty
    case tab
    case shiftTab
    case escape
    /// A click on the chip of level `index`: pop every level above it.
    case popTo(Int)
    /// Return, or a click on row `rowID` (nil: the selection).
    case activate(String?)
    /// A command pushed its own page `scope` (entry `command`), from row
    /// `row` of the top level, with `query` typed (a rename's current name).
    case push(PaletteScopeID, row: String?, query: String)
    /// Arrow keys; wraps.
    case move(Int)
    case select(String)
    /// A batch from the source of `levelID` for `generation`.
    /// `emptyQuerySelection` overrides the scope's index for this batch (a
    /// page that decides it from its rows, such as Search Tabs).
    case results(levelID: Int, generation: Int, rows: [PaletteNavRow], replace: Bool, isFinal: Bool,
                 emptyQuerySelection: Int? = nil)
    /// The owner of the top level's data changed: reload, keep selection.
    case refresh
}

/// Work for the palette model after a reducer step.
nonisolated public enum PaletteNavEffect: Equatable, Sendable {
    /// Ask the scope's source for `query`; tag batches with `generation`.
    case load(levelID: Int, scope: PaletteScopeID, query: String, generation: Int, context: String?)
    /// Stop the level's sources (it was popped or the palette closed).
    case cancel(levelID: Int)
    /// Run the primary command of `rowID`.
    case run(levelID: Int, rowID: String)
    /// Open the Actions menu of `rowID` (Tab with nothing to enter).
    case openActions(rowID: String)
    /// Hide the palette.
    case dismiss
    /// Accessibility announcement: the scope now on top.
    case announceEntered(PaletteScopeID)
    case announceLeft(to: PaletteScopeID)
    case refused(PaletteNavRefusal)
}

nonisolated public enum PaletteNavRefusal: Equatable, Sendable {
    case depthLimit
}
