/// Value snapshot rendered by the Fleet board.
public struct FleetBoardSnapshot: Equatable, Sendable {
    /// The selected Fleet summary, when one exists.
    public var selectedFleet: FleetBoardFleetSummary?

    /// Every configured Fleet available to the picker.
    public var fleets: [FleetBoardFleetSummary]

    /// Rows grouped by board column.
    public var columns: [FleetBoardColumn: [FleetBoardRowSnapshot]]

    /// Creates a Fleet board snapshot.
    /// - Parameters:
    ///   - selectedFleet: The selected Fleet summary, when one exists.
    ///   - fleets: Every configured Fleet available to the picker.
    ///   - columns: Rows grouped by board column.
    public init(
        selectedFleet: FleetBoardFleetSummary?,
        fleets: [FleetBoardFleetSummary],
        columns: [FleetBoardColumn: [FleetBoardRowSnapshot]]
    ) {
        self.selectedFleet = selectedFleet
        self.fleets = fleets
        self.columns = columns
    }

    /// An empty board snapshot.
    public static var empty: FleetBoardSnapshot {
        FleetBoardSnapshot(
            selectedFleet: nil,
            fleets: [],
            columns: Dictionary(uniqueKeysWithValues: FleetBoardColumn.allCases.map { ($0, []) })
        )
    }
}
