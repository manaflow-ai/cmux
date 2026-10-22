public import CmuxNextDesign

nonisolated extension SidebarTunables {
    /// Shows the Update Ready card and its preview for a pretend staged update with the newest
    /// real, published notes (the app falls back to sample notes offline). Nothing downloads or
    /// installs; turning it off follows the real updater again (`UpdateSimulation`).
    public static let simulatePendingUpdate = Tunable<Bool>.toggle(
        "sidebar.updateCard.simulatePending", .sidebar, "Simulate pending update",
        help: "Shows the Update Ready card and its changelog preview with the newest published notes. Nothing installs.",
        default: false, code: "SidebarTunables.simulatePendingUpdate")
}
