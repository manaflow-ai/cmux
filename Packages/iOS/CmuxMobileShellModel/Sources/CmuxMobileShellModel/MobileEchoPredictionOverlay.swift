/// The renderable snapshot of outstanding echo predictions for one surface.
///
/// The engine always tracks predictions internally; `displayState` says
/// whether the renderer should draw them. Provisional cells render
/// underline-until-confirmed (mosh semantics); confirmation removes the cell
/// from `cells`, and the authoritative grid underneath already shows the echo.
public struct MobileEchoPredictionOverlay: Equatable, Sendable {
    public enum DisplayState: Equatable, Sendable {
        /// Predictions are tracked silently while the engine rebuilds
        /// confidence (startup, after a mispredict, or in a no-echo context).
        case tentative
        /// Predictions have been recently confirmed; draw the overlay.
        case active
    }

    public struct Cell: Equatable, Sendable {
        public var row: Int
        public var column: Int
        public var character: Character

        public init(row: Int, column: Int, character: Character) {
            self.row = row
            self.column = column
            self.character = character
        }
    }

    public var displayState: DisplayState
    /// The epoch every listed cell belongs to; a contradiction invalidates all
    /// of them at once.
    public var epoch: UInt64
    /// Outstanding (unconfirmed) predicted cells in registration order.
    public var cells: [Cell]
    /// Where the cursor sits if every outstanding prediction echoes.
    public var predictedCursorRow: Int?
    public var predictedCursorColumn: Int?

    /// Whether the renderer should draw anything right now.
    public var isVisible: Bool {
        displayState == .active && !cells.isEmpty
    }

    public init(
        displayState: DisplayState,
        epoch: UInt64,
        cells: [Cell],
        predictedCursorRow: Int? = nil,
        predictedCursorColumn: Int? = nil
    ) {
        self.displayState = displayState
        self.epoch = epoch
        self.cells = cells
        self.predictedCursorRow = predictedCursorRow
        self.predictedCursorColumn = predictedCursorColumn
    }
}
