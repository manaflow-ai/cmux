import CmuxNextHomeEngine

// TEMPORARY (UI lane): the app lane implements this in its own branch; drop this file at integration.
extension AppServices {
    /// The control lease of a Chief's computer: `agent` for a Cloud Chief's own sandbox, `machine` for
    /// a Cloud machine a Chief of this Mac uses. Nil until the app lane lands.
    @MainActor func chiefComputerControlSource(agent: String?, machine: String?) -> HomeChiefComputerControlSource? {
        nil
    }
}
