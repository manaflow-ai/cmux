/// The closures behind the "+" toolbar menu. Every entry point that opens a
/// terminal (tap, menu row, Computers sheet) funnels into these.
struct MobileNewTerminalMenuActions {
    let createWorkspace: () -> Void
    let createWorkspaceGroup: (() -> Void)?
    /// Switch the foreground connection to the host and open a new workspace there.
    let openTerminal: (MobileNewTerminalMenuValue.Host) -> Void
    let openLocalLinux: () -> Void
    let addComputer: (() -> Void)?

    static let inert = MobileNewTerminalMenuActions(
        createWorkspace: {},
        createWorkspaceGroup: nil,
        openTerminal: { _ in },
        openLocalLinux: {},
        addComputer: nil
    )
}
