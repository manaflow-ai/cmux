import CmuxNextActions

/// One row of the which-key overlay: the key after the leader and the
/// action it runs.
struct WhichKeyRow: Equatable {
    var key: String
    var title: String
    /// False when the action cannot run in this focus (drawn dimmed).
    var isEnabled: Bool
}

/// The which-key overlay's rows. Stub.
enum WhichKeyListing {
    static func rows(after prefix: Shortcut, in registry: ActionRegistry) -> [WhichKeyRow] { [] }
}
