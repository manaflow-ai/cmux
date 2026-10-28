/// One complete census projected onto the live terminal panes.
struct RunawayPaneWarningMeasurement: Sendable {
    let warnings: [PaneMemoryPaneKey: RunawayPaneWarning]
    let unavailableKeys: Set<PaneMemoryPaneKey>
    let recoveredKeys: Set<PaneMemoryPaneKey>
}
