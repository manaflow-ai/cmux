/// The `diagnostics.usageRecording` row: Settings > Privacy and Security > Usage Recording,
/// after Hang Reports.
nonisolated enum UsageRecordingSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.usageRecording", "Usage Recording")
        return [
            SettingDescriptor(
                UsageRecordingSetting.path, section: .home, group: group,
                title: SettingsText.keyed("settings.diagnostics.usageRecording", "Record Usage on This Mac"),
                help: SettingsText.keyed(
                    "settings.diagnostics.usageRecording.help",
                    "Keeps a local record of how you use cmux: whether you are in a terminal, a browser or an agent chat, which commands run and whether from a key, a click or the CLI, how long they take, and counts of open windows, panes and tabs. It never includes file names, web addresses, titles, terminal or chat text, or anything you type. The record stays on this Mac."),
                summary: SettingsText.keyed("settings.diagnostics.usageRecording.summary", "Stays on this Mac. No file names, text or addresses."),
                kind: .toggle, default: .bool(UsageRecordingSetting.defaultValue),
                keywords: ["usage", "analytics", "statistics", "diagnostics", "telemetry", "privacy", "record", "patterns"]
            ),
        ]
    }
}
