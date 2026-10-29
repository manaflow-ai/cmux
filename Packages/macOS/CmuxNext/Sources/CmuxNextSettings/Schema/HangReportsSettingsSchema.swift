/// The `diagnostics.hangReports` row: Settings > Privacy and Security > Hang Reports, with the
/// View Hang Report button at the end of the category (`SettingsSchema.actions(in: .home)`).
nonisolated enum HangReportsSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.hangReports", "Hang Reports")
        return [
            SettingDescriptor(
                HangReportsSetting.path, section: .home, group: group,
                title: SettingsText.keyed("settings.diagnostics.hangReports", "Send Hang Reports"),
                help: SettingsText.keyed(
                    "settings.diagnostics.hangReports.help",
                    "Nightly builds send a daily report of hangs and slow frames: call stacks of cmux and macOS code, durations, your app and macOS versions, your Mac's chip and memory size, and rounded counts of open windows and tabs. It never includes file names, web addresses, terminal text, names or anything you type. View Hang Report shows exactly what is sent."),
                summary: SettingsText.keyed("settings.diagnostics.hangReports.summary", "Nightly only. No file names, text or addresses."),
                kind: .toggle, default: .bool(HangReportsSetting.defaultValue),
                keywords: ["hang", "lag", "slow", "performance", "diagnostics", "telemetry", "privacy", "metrickit", "report"]
            ),
        ]
    }
}
