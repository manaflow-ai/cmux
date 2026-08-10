/// Immutable state that controls whether the workspace chrome presents Simulator panels.
struct SimulatorPickerMenuValue: Equatable {
    let rows: [SimulatorStreamPickerRow]
    let activePanelID: String?

    init(
        supportsSimulatorStream: Bool,
        rows: [SimulatorStreamPickerRow],
        activePanelID: String?
    ) {
        self.rows = supportsSimulatorStream ? rows : []
        self.activePanelID = self.rows.contains(where: { $0.id == activePanelID })
            ? activePanelID
            : nil
    }

    var isVisible: Bool {
        !rows.isEmpty
    }

    /// The current panel wins; otherwise the first authoritative workspace row is deterministic.
    var targetPanelID: String? {
        activePanelID ?? rows.first?.id
    }
}
