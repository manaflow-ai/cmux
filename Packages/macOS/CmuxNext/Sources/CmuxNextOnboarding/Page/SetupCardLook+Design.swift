public import CmuxNextDesign
public import CmuxNextSettings

extension SetupCardLook {
    /// The row the app shows: Text Size and density as `design` draws them now, each pick written through
    /// `settings` (`SettingsController.setSetting`, by the person) as Settings > General's Text Size card writes it.
    ///
    /// - Parameters:
    ///   - design: The live design settings (`DesignSettings.shared` in the app).
    ///   - settings: The settings writer, or nil before settings load (a pick then writes nothing).
    public init(design: DesignSettings, settings: @escaping @MainActor () -> SettingsController?) {
        self.init(
            current: {
                Current(textSize: design.overrides[.chromeFontSize].map(Double.init), density: design.densityTokens.id,
                        body: Double(design.densityTokens.bodySize))
            },
            write: { path, value in
                guard let settings = settings() else { return }
                try await settings.setSetting(at: path, to: value, by: .user)
            })
    }
}
