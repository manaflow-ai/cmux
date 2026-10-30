/// The `input.*` rows (``DragResampleSettings``). Off the Settings page and the palette while their
/// feature (`resampledDrags`) is off by default; the schema export lists them.
nonisolated enum InputSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.pointerInput", "Pointer Input")
        return [
            SettingDescriptor(
                DragResampleSettings.resampleDragsPath, section: .appearance, group: group,
                title: SettingsText.keyed("settings.input.resampleDrags", "Smooth Divider Drags"),
                help: SettingsText.keyed(
                    "settings.input.resampleDrags.help",
                    "A dragged divider or pane edge is drawn where the pointer was at each frame's time, so it moves at an even pace. Snaps and where it lands still follow the pointer exactly. Reduce Motion turns it off."),
                kind: .toggle, default: .bool(DragResampleSettings.resampleDragsDefault),
                keywords: ["drag", "divider", "resize", "smooth", "pointer", "mouse", "resample", "frame"]
            )
            .hiddenFromSettingsPage("behind the resampledDrags feature (off by default)"),
            SettingDescriptor(
                DragResampleSettings.frameAheadPath, section: .development, group: group,
                title: SettingsText.keyed("settings.input.resampleFrameAheadMs", "Drag Prediction Ahead"),
                help: SettingsText.keyed(
                    "settings.input.resampleFrameAheadMs.help",
                    "Draws a dragged divider this far ahead of the frame, guessed from the pointer's speed. 0 does not guess ahead. Snaps and where it lands still follow the real pointer."),
                kind: .number(SettingNumber(DragResampleSettings.frameAheadRange, step: 1, unit: .milliseconds)),
                default: .number(DragResampleSettings.frameAheadDefault),
                keywords: ["drag", "divider", "prediction", "predict", "latency", "resample", "debug", "development"]
            )
            .hiddenFromSettingsPage("a debug knob of the resampledDrags feature (off by default)"),
        ]
    }
}
