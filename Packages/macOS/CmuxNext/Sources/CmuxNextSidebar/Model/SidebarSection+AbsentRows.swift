/// Rows of workspaces a window keeps while no machine lists them (P-AUSTIN B7: a Cloud workspace
/// while signed out of cmux Cloud, Cloud turned off, its machine paused or not loaded yet). Each
/// row goes in its machine's section, after that section's rows; a machine with no section gets one,
/// after the others, headed by `header`. A row any section lists already is left out, so a
/// machine's own or saved rows always win.
nonisolated extension SidebarSection {
    public static func adding(absent rows: [SidebarWorkspace], header: (MachineID) -> SidebarMachine,
                       to sections: [SidebarSection]) -> [SidebarSection] {
        sections // red stub
    }
}
