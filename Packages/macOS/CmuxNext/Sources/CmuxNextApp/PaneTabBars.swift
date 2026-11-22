import CmuxNextSettings

extension PaneController {
    /// Whether the pane hides its tab bar now: only when the person hid it.
    var hidesTabBar: Bool { services.paneTabBars.choice(for: paneKey) == false }
}
