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

    /// Returns the first panel to enter when Simulator is inactive. An active
    /// Simulator makes the toolbar control a return action instead.
    var targetPanelID: String? {
        activePanelID == nil ? rows.first?.id : nil
    }
}
