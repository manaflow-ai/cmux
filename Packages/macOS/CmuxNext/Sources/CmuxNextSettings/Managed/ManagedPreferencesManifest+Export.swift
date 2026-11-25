public import Foundation

extension ManagedPreferencesManifest {
    /// Every file `docs/mdm` publishes, by file name: the one list `ManagedPreferencesManifestTests`
    /// compares with the checked-in copies and the Linux exporter
    /// (`Packages/Shared/CmuxNextSettingsExport`) writes.
    public static func exportFiles() throws -> [(name: String, data: Data)] {
        [
            ("com.manaflow.cmux.plist", try profileManifest()),
            ("com.manaflow.cmux.json", try jamfSchema() + Data("\n".utf8)),
            ("cmux-example.mobileconfig", try exampleMobileconfig()),
            ("com.manaflow.cmux.intune.plist", Data(try intunePreferenceFile().utf8)),
            ("managed-preferences.md", Data(markdown().utf8)),
        ]
    }
}
