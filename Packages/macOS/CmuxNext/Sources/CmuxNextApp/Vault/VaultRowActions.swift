import CmuxNextActions

/// What a vault row can ask for: runs one `vault*` action on the row's session
/// (the registry path every entrypoint takes), and picks the row.
struct VaultRowActions {
    let perform: @MainActor (ActionID, String) -> Void
    let select: @MainActor (String) -> Void
}
