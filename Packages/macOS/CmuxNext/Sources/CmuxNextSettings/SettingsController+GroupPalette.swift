public import CmuxNextDesign

extension SettingsController {
    /// The group editor's palette marble (`sidebar.groupPalette`, Leo 2026-11-06: "you pick this circle, right? And
    /// it's like this ball of colors"): every group draws from `palette` in this turn, and cmux.json keeps it once
    /// the write lands, as the Settings row, the palette, the CLI and MCP write it.
    public func setGroupPalette(_ palette: GroupPalette) {
        DesignSettings.shared.sidebarSections.groupPalette = palette
        // task-owner: one settings write; ends when it lands (the snapshot brings the same value back).
        // main-hop-allow: the person's click already changed the model above; this only awaits the file write, no UI work.
        Task { @MainActor [weak self] in
            try? await self?.setSetting(at: SidebarSectionsSetting.groupPalettePath, to: .string(palette.rawValue), by: .user)
        }
    }
}
