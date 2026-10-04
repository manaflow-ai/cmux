public import CmuxNextDesign

/// Split, new column, docked column and minimum pane size settings
/// (plans/cmux-next/column-sizing.md), in the General section's Columns group.
extension SettingsSchema {
    static var columnLayout: [SettingDescriptor] {
        let columns = SettingsText.keyed("settings.group.columns", "Columns")
        return [
            SettingDescriptor(
                ColumnLayoutSettings.splitSizingPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.splitSizing", "Split Sizing"),
                help: SettingsText.keyed("settings.layout.splitSizing.help", "Even gives every pane in the column the same size after a split."),
                kind: .choice([
                    SettingChoice(SplitSizing.even.rawValue, SettingsText.keyed("settings.choice.splitEven", "Even")),
                    SettingChoice(SplitSizing.halve.rawValue, SettingsText.keyed("settings.choice.splitHalve", "Halve the Pane")),
                ]),
                default: .string(ColumnLayoutSettings.splitSizingFallback.rawValue), keywords: ["split", "equal", "size"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.newColumnWidthPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.newColumnWidthMode", "New Column Sizing"),
                kind: .choice([
                    SettingChoice(NewColumnWidthMode.matchCurrent.rawValue, SettingsText.keyed("settings.choice.matchCurrent", "Match Current Column")),
                    SettingChoice(NewColumnWidthMode.fitScreen.rawValue, SettingsText.keyed("settings.choice.fitScreen", "Fit Visible Columns")),
                    SettingChoice(NewColumnWidthMode.fixed.rawValue, SettingsText.keyed("settings.choice.fixedWidth", "Fixed Width")),
                ]),
                default: .string(ColumnLayoutSettings.newColumnWidthFallback.rawValue), keywords: ["width", "column"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.dockEdgePath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.dockColumnEdge", "Dock Column Edge"),
                kind: .choice([
                    SettingChoice(DockDefaultEdge.nearest.rawValue, SettingsText.keyed("settings.choice.nearestEdge", "Nearest Edge")),
                    SettingChoice(DockDefaultEdge.right.rawValue, SettingsText.keyed("settings.choice.right", "Right")),
                    SettingChoice(DockDefaultEdge.left.rawValue, SettingsText.keyed("settings.choice.left", "Left")),
                    SettingChoice(DockDefaultEdge.top.rawValue, SettingsText.keyed("settings.choice.top", "Top")),
                    SettingChoice(DockDefaultEdge.bottom.rawValue, SettingsText.keyed("settings.choice.bottom", "Bottom")),
                ]),
                default: .string(ColumnLayoutSettings.dockEdgeFallback.rawValue), keywords: ["dock", "pin", "column"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.dockModePath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.dockColumnMode", "Dock Column Mode"),
                kind: .choice([
                    SettingChoice(DockDefaultMode.docked.rawValue, SettingsText.keyed("settings.choice.docked", "Docked")),
                    SettingChoice(DockDefaultMode.overlay.rawValue, SettingsText.keyed("settings.choice.overlay", "Floating")),
                ]),
                default: .string(ColumnLayoutSettings.dockModeFallback.rawValue), keywords: ["floating", "overlay", "dock"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.frameOrientationPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.frameOrientation", "Dock Corners"),
                kind: .choice([
                    SettingChoice(FrameOrientation.columnMajor.rawValue, SettingsText.keyed("settings.choice.columnMajor", "Side Docks Full Height")),
                    SettingChoice(FrameOrientation.rowMajor.rawValue, SettingsText.keyed("settings.choice.rowMajor", "Top and Bottom Docks Full Width")),
                ]),
                default: .string(ColumnLayoutSettings.frameOrientationFallback.rawValue), keywords: ["dock", "frame", "orientation", "corner"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.rowsPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.rows", "Rows"),
                help: SettingsText.keyed("settings.layout.rows.help",
                                        "Off hides New Row and fits a column's existing rows into it without scrolling."),
                kind: .toggle, default: .bool(ColumnLayoutSettings.rowsFallback), keywords: ["row", "column", "scroll", "vertical"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.minimumPaneWidthPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.minimumPaneWidth", "Minimum Pane Width"),
                kind: .number(SettingNumber(ColumnLayoutSettings.minimumPaneWidthRange, step: 10, unit: .points)),
                default: .number(ColumnLayoutSettings.minimumPaneWidthFallback), keywords: ["split", "size", "width"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.minimumPaneHeightPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.minimumPaneHeight", "Minimum Pane Height"),
                kind: .number(SettingNumber(ColumnLayoutSettings.minimumPaneHeightRange, step: 4, unit: .points)),
                default: .number(ColumnLayoutSettings.minimumPaneHeightFallback), keywords: ["split", "size", "height"]
            ),
        ]
    }
}
