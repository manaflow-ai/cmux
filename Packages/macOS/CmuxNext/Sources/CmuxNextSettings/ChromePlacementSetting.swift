public import CmuxNextDesign

/// Where the window chrome sits (R109): `sidebar.side` and
/// `sidebar.spacesPosition` in cmux-next.json. A missing key is the
/// default; a bad value is the default plus a diagnostic.
public nonisolated enum ChromePlacementSetting {
    public static let sidebarSidePath = ["sidebar", "side"]
    public static let spacesPositionPath = ["sidebar", "spacesPosition"]

    static func parse(_ root: JSONValue, into snapshot: inout CmuxConfigSnapshot) {
    }
}

extension SettingsApplier {
    /// Copies the chrome placement keys into `design`, writing only changes.
    public static func applyPlacement(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
    }
}
