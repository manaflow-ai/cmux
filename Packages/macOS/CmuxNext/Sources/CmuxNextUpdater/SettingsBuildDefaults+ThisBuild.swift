import CmuxNextCompat
public import CmuxNextSettings

extension SettingsBuildDefaults {
    /// This build's settings defaults: the app's settings (`SettingsController.readAtLaunch`) and, through
    /// `CMUX_NEXT_SETTINGS_BUILD_DEFAULTS` (``BuildStatePaths/settingsBuildDefaultsKey``), the Rust settings owner
    /// behind `cmux settings` and MCP `settings_get`, so both report one value.
    public static var thisBuild: SettingsBuildDefaults {
        let track = UpdateBuildIdentity.main().track
        return .channel(downloadsAutomatically: track.downloadsAutomaticallyByDefault,
                        devBuild: BuildStatePaths.current.isolatesSharedState, installsWhenIdle: track.installsWhenIdleByDefault)
    }
}
