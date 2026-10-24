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
                    "settings.diagnostics.hangReports.helpConsent",
                    "Nightly builds send a daily report of hangs and slow frames: call stacks of cmux and macOS code, durations, your app and macOS versions, your Mac's chip and memory size, and rounded counts of open windows and tabs. It never includes file names, web addresses, terminal text, names or anything you type. This choice is separate from anonymous usage data: with that off, cmux never asks, but this switch still works. Each Mac sends only after you turn this on there; a settings file copied from another Mac does not turn it on. View Hang Report shows exactly what is sent."),
                summary: SettingsText.keyed("settings.diagnostics.hangReports.summary", "Nightly only. No file names, text or addresses."),
                kind: .toggle, default: .bool(HangReportsSetting.defaultValue),
                keywords: ["hang", "lag", "slow", "performance", "diagnostics", "telemetry", "privacy", "metrickit", "report"]
            ),
        ]
    }
}
