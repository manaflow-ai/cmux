extension CmuxConfigSnapshot {
    /// `appearance.videoWallpaperIdlePause`: seconds with no keyboard or mouse input before a video
    /// background (a local movie or YouTube) pauses; the next input resumes it. 0 never pauses; 300
    /// unless set, and a bad value is 300 too (`WindowBackgroundSetting.parse` reports it).
    public var videoWallpaperIdlePause: Double {
        var ignored: [SettingsDiagnostic] = []
        return WindowBackgroundSetting.parseVideoWallpaperIdlePause(root, diagnostics: &ignored)
    }
}
