public import CmuxNextDesign

/// Split, new column, docked column and minimum pane size settings
/// (plans/cmux-next/column-sizing.md), in the General section's Columns group.
/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum ColumnLayoutSettingsSchema {
    static var descriptors: [SettingDescriptor] {
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
                default: .string(ColumnLayoutSettings.splitSizingFallback.rawValue),
                keywords: ["split", "equal", "size", "autobalance", "balance", "equalize"]
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
                summary: SettingsText.keyed("settings.layout.rows.summary", "Rows of panes inside a column"),
                kind: .toggle, default: .bool(ColumnLayoutSettings.rowsFallback), keywords: ["row", "column", "scroll", "vertical"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.focusFollowsMousePath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.focusFollowsMouse", "Focus Follows Mouse"),
                help: SettingsText.keyed("settings.layout.focusFollowsMouse.help",
                                        "Moving the pointer onto a pane or scrolling over it focuses that pane. Off keeps focus where you type until you click. Momentum and the first second after typing never move focus."),
                summary: SettingsText.keyed("settings.layout.focusFollowsMouse.summary", "Hovering or scrolling a pane focuses it"),
                kind: .toggle, default: .bool(ColumnLayoutSettings.focusFollowsMouseFallback),
                keywords: ["focus", "scroll", "wheel", "trackpad", "pane", "follows mouse", "hover", "pointer"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.scrollAreasPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.scrollAreas", "Scroll Areas"),
                help: SettingsText.keyed("settings.layout.scrollAreas.help",
                                        "Side-by-side panes that do not fit scroll sideways instead of shrinking, also in docked columns."),
                summary: SettingsText.keyed("settings.layout.scrollAreas.summary", "Splits scroll instead of squashing"),
                kind: .toggle, default: .bool(ColumnLayoutSettings.scrollAreasFallback),
                keywords: ["scroll", "area", "split", "squash", "dock", "horizontal", "overflow"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.scrollModifierPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.scrollModifier", "Scroll Columns and Rows With"),
                help: SettingsText.keyed("settings.layout.scrollModifier.help",
                                        "Command + Scroll moves columns and rows from anywhere, and a plain scroll always scrolls the pane under the pointer. Without a modifier, a sideways scroll moves columns unless the pane scrolls sideways itself, and rows scroll only over the gaps between them."),
                summary: SettingsText.keyed("settings.layout.scrollModifier.summary", "Command + Scroll moves columns and rows"),
                kind: .choice([
                    SettingChoice(LayoutScrollModifier.command.rawValue, SettingsText.keyed("settings.choice.scrollModifierCommand", "Command + Scroll")),
                    SettingChoice(LayoutScrollModifier.noModifier.rawValue, SettingsText.keyed("settings.choice.scrollModifierNone", "Scroll Without a Modifier")),
                ]),
                default: .string(ColumnLayoutSettings.scrollModifierFallback.rawValue),
                keywords: ["scroll", "command", "modifier", "wheel", "trackpad", "columns", "rows", "strip", "pan", "horizontal"]
            ),
            SettingDescriptor(
                ColumnLayoutSettings.pagesHandleCommandScrollPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.pagesHandleCommandScroll", "Web Pages Get Command + Scroll First"),
                help: SettingsText.keyed("settings.layout.pagesHandleCommandScroll.help",
                                        "A web page that uses Command + Scroll itself, such as Figma or Excalidraw zooming, keeps it. Over any other page, Command + Scroll moves columns. Off, Command + Scroll always moves columns."),
                summary: SettingsText.keyed("settings.layout.pagesHandleCommandScroll.summary", "Figma and Excalidraw keep Command + Scroll zoom"),
                kind: .toggle, default: .bool(ColumnLayoutSettings.pagesHandleCommandScrollFallback),
                keywords: ["scroll", "command", "zoom", "figma", "excalidraw", "browser", "web", "page", "columns", "pan"]
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
