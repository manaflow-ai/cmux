public import CmuxNextDesign

/// Settings > Appearance > Motion: the master switch `ui.animations.enabled`
/// and one switch per ``MotionCategory`` (``MotionCategoriesSetting``,
/// plans/cmux-next/motion-DESIGN.md).
nonisolated enum MotionSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let motion = SettingsText.keyed("settings.group.motion", "Motion")
        return [
            SettingDescriptor(
                CalmModeSetting.configPath, section: .appearance, group: motion,
                title: SettingsText.keyed("settings.ui.calm", "Calm Mode"),
                help: SettingsText.keyed("settings.ui.calm.help",
                                        "Calm: nothing slides, springs or spins, hover cards stay closed and the pointer leaves no highlight on tabs, rows and buttons. Still: Calm, and every animation is instant. Your other motion and hover card settings come back when it is off."),
                kind: .choice([
                    SettingChoice(CalmMode.off.rawValue, SettingsText.keyed("settings.choice.off", "Off")),
                    SettingChoice(CalmMode.calm.rawValue, SettingsText.keyed("settings.choice.calm", "Calm")),
                    SettingChoice(CalmMode.still.rawValue, SettingsText.keyed("settings.choice.still", "Still")),
                ]),
                default: .string(CalmModeSetting.fallback.rawValue),
                keywords: ["calm", "quiet", "focus", "zen", "reduce motion", "reduced motion", "hover", "no hover",
                           "highlight", "distraction", "busy", "noise", "minimal", "still"]
            ),
            SettingDescriptor(
                MotionCategoriesSetting.enabledPath, section: .appearance, group: motion,
                title: SettingsText.keyed("settings.ui.animations.enabled", "Play Animations"),
                help: SettingsText.keyed("settings.ui.animations.enabled.help",
                                        "Off turns every animation in cmux off: rows, tabs, panes, menus, cards, the agent cursor, spinners and cmux web pages change at once. On, the switches below choose area by area."),
                kind: .toggle, default: .bool(MotionCategoriesSetting.enabledFallback),
                keywords: ["motion", "animation", "animations", "no animations", "disable animations", "reduce motion", "instant"]
            ),
            SettingDescriptor(
                MotionCategoriesSetting.path(.sidebar), section: .appearance, group: motion,
                title: SettingsText.keyed("settings.ui.animations.sidebar", "Animate the Sidebar"),
                help: SettingsText.keyed("settings.ui.animations.sidebar.help",
                                        "Rows and groups slide when they reorder, open, close, pin or move to the top, and the sidebar slides when it shows or hides. Off: they change at once."),
                kind: .toggle, default: .bool(MotionCategoriesSetting.categoryFallback),
                keywords: ["motion", "animation", "sidebar", "row", "group", "reorder", "pin", "move to top"]
            ),
            SettingDescriptor(
                MotionCategoriesSetting.path(.tabs), section: .appearance, group: motion,
                title: SettingsText.keyed("settings.ui.animations.tabs", "Animate Tabs"),
                help: SettingsText.keyed("settings.ui.animations.tabs.help",
                                        "Tabs grow, shrink and slide when they open, close, reorder or collapse into a group. Off: the tab bar changes at once."),
                kind: .toggle, default: .bool(MotionCategoriesSetting.categoryFallback),
                keywords: ["motion", "animation", "tab", "tab bar", "reorder", "group"]
            ),
            SettingDescriptor(
                MotionCategoriesSetting.path(.panes), section: .appearance, group: motion,
                title: SettingsText.keyed("settings.ui.animations.panes", "Animate Panes and Windows"),
                help: SettingsText.keyed("settings.ui.animations.panes.help",
                                        "Splits, closes, zooms, dividers, focus rings, drop zones and windows open, close and move with motion. Off: they change at once."),
                kind: .toggle, default: .bool(MotionCategoriesSetting.categoryFallback),
                keywords: ["motion", "animation", "pane", "split", "zoom", "window", "divider", "focus ring"]
            ),
            SettingDescriptor(
                MotionCategoriesSetting.path(.overlays), section: .appearance, group: motion,
                title: SettingsText.keyed("settings.ui.animations.overlays", "Animate Menus and Cards"),
                help: SettingsText.keyed("settings.ui.animations.overlays.help",
                                        "Menus, popovers, the command palette, sheets, toasts, notices, find bars and cards fade and slide in and out. Off: they show and hide at once."),
                kind: .toggle, default: .bool(MotionCategoriesSetting.categoryFallback),
                keywords: ["motion", "animation", "menu", "popover", "palette", "toast", "card", "sheet", "find bar"]
            ),
            SettingDescriptor(
                MotionCategoriesSetting.path(.hoverCards), section: .appearance, group: motion,
                title: SettingsText.keyed("settings.ui.animations.hoverCards", "Animate Hover Cards"),
                help: SettingsText.keyed("settings.ui.animations.hoverCards.help",
                                        "Hover cards and tooltips fade and slide in. Off: they show and hide at once."),
                kind: .toggle, default: .bool(MotionCategoriesSetting.categoryFallback),
                keywords: ["motion", "animation", "hover card", "tooltip", "preview"]
            ),
            SettingDescriptor(
                MotionCategoriesSetting.path(.home), section: .appearance, group: motion,
                title: SettingsText.keyed("settings.ui.animations.home", "Animate Home and Chats"),
                help: SettingsText.keyed("settings.ui.animations.home.help",
                                        "The Chief chat, its bubbles, the composer and the Home list move and fade. Off: they change at once."),
                kind: .toggle, default: .bool(MotionCategoriesSetting.categoryFallback),
                keywords: ["motion", "animation", "home", "chief", "chat", "bubble", "messages"]
            ),
            SettingDescriptor(
                MotionCategoriesSetting.path(.cursor), section: .appearance, group: motion,
                title: SettingsText.keyed("settings.ui.animations.cursor", "Animate the Agent Cursor"),
                help: SettingsText.keyed("settings.ui.animations.cursor.help",
                                        "The agent cursor glides between points and shows click ripples. Off: it jumps and shows no ripple."),
                kind: .toggle, default: .bool(MotionCategoriesSetting.categoryFallback),
                keywords: ["motion", "animation", "cursor", "agent", "computer use", "ripple"]
            ),
            SettingDescriptor(
                MotionCategoriesSetting.path(.indicators), section: .appearance, group: motion,
                title: SettingsText.keyed("settings.ui.animations.indicators", "Animate Spinners and Progress"),
                help: SettingsText.keyed("settings.ui.animations.indicators.help",
                                        "Spinners turn, status dots pulse and attention flashes blink. Off: they show a still glyph."),
                kind: .toggle, default: .bool(MotionCategoriesSetting.categoryFallback),
                keywords: ["motion", "animation", "spinner", "progress", "pulse", "flash", "loading", "status"]
            ),
            SettingDescriptor(
                MotionCategoriesSetting.path(.feedback), section: .appearance, group: motion,
                title: SettingsText.keyed("settings.ui.animations.feedback", "Animate Highlights and Colors"),
                help: SettingsText.keyed("settings.ui.animations.feedback.help",
                                        "Hover and press highlights, focus fades and theme color changes ease in. Off: they change at once."),
                kind: .toggle, default: .bool(MotionCategoriesSetting.categoryFallback),
                keywords: ["motion", "animation", "hover", "highlight", "focus", "color", "theme", "transition"]
            ),
            SettingDescriptor(
                MotionCategoriesSetting.path(.web), section: .appearance, group: motion,
                title: SettingsText.keyed("settings.ui.animations.web", "Animate cmux Web Pages"),
                help: SettingsText.keyed("settings.ui.animations.web.help",
                                        "Transitions and animations in cmux's own pages, such as agent chats, New Tab and Markdown. Off: they end at once. Websites are not changed."),
                kind: .toggle, default: .bool(MotionCategoriesSetting.categoryFallback),
                keywords: ["motion", "animation", "web", "page", "css", "transition", "new tab", "markdown", "agent chat"]
            ),
        ]
    }
}
