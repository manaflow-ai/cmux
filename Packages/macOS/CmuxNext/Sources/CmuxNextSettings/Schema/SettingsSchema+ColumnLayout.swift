public import CmuxNextDesign

/// Split, new column, sticky column and minimum pane size settings
/// (plans/cmux-next/column-sizing.md), in the General section's Columns group.
extension SettingsSchema {
    static var columnLayout: [SettingDescriptor] {
        let columns = SettingsText.text("settings.group.columns", "Columns")
        return [
            SettingDescriptor(
                ColumnLayoutSettings.splitSizingPath, section: .general, group: columns,
                title: SettingsText.text("settings.layout.splitSizing", "Split Sizing"),
                help: SettingsText.text("settings.layout.splitSizing.help", "Even gives every pane in the column the same size after a split."),
                kind: .choice([
                    SettingChoice(SplitSizing.even.rawValue, SettingsText.text("settings.choice.splitEven", "Even")),
                    SettingChoice(SplitSizing.halve.rawValue, SettingsText.text("settings.choice.splitHalve", "Halve the Pane")),
                ]),
                default: .string(ColumnLayoutSettings.splitSizingFallback.rawValue), keywords: ["split", "equal", "size"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.newColumnWidthPath, section: .general, group: columns,
                title: SettingsText.text("settings.layout.newColumnWidthMode", "New Column Sizing"),
                kind: .choice([
                    SettingChoice(NewColumnWidthMode.matchCurrent.rawValue, SettingsText.text("settings.choice.matchCurrent", "Match Current Column")),
                    SettingChoice(NewColumnWidthMode.fitScreen.rawValue, SettingsText.text("settings.choice.fitScreen", "Fit Visible Columns")),
                    SettingChoice(NewColumnWidthMode.fixed.rawValue, SettingsText.text("settings.choice.fixedWidth", "Fixed Width")),
                ]),
                default: .string(ColumnLayoutSettings.newColumnWidthFallback.rawValue), keywords: ["width", "column"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.stickyEdgePath, section: .general, group: columns,
                title: SettingsText.text("settings.layout.stickyColumnEdge", "Sticky Column Edge"),
                kind: .choice([
                    SettingChoice(StickyDefaultEdge.right.rawValue, SettingsText.text("settings.choice.right", "Right")),
                    SettingChoice(StickyDefaultEdge.left.rawValue, SettingsText.text("settings.choice.left", "Left")),
                ]),
                default: .string(ColumnLayoutSettings.stickyEdgeFallback.rawValue), keywords: ["sticky", "pin", "column"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.stickyModePath, section: .general, group: columns,
                title: SettingsText.text("settings.layout.stickyColumnMode", "Sticky Column Mode"),
                kind: .choice([
                    SettingChoice(StickyDefaultMode.docked.rawValue, SettingsText.text("settings.choice.docked", "Docked")),
                    SettingChoice(StickyDefaultMode.overlay.rawValue, SettingsText.text("settings.choice.overlay", "Overlay")),
                ]),
                default: .string(ColumnLayoutSettings.stickyModeFallback.rawValue), keywords: ["sticky", "overlay", "dock"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.minimumPaneWidthPath, section: .general, group: columns,
                title: SettingsText.text("settings.layout.minimumPaneWidth", "Minimum Pane Width"),
                kind: .number(SettingNumber(ColumnLayoutSettings.minimumPaneWidthRange, step: 10, unit: .points)),
                default: .number(ColumnLayoutSettings.minimumPaneWidthFallback), keywords: ["split", "size", "width"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.minimumPaneHeightPath, section: .general, group: columns,
                title: SettingsText.text("settings.layout.minimumPaneHeight", "Minimum Pane Height"),
                kind: .number(SettingNumber(ColumnLayoutSettings.minimumPaneHeightRange, step: 4, unit: .points)),
                default: .number(ColumnLayoutSettings.minimumPaneHeightFallback), keywords: ["split", "size", "height"]
            ),
        ]
    }
}
