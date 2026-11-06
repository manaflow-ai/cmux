/// Settings > Chief > Subagents: which Chief subagents get a workspace in the sidebar (a1018, Lawrence
/// 2026-11-05: "the chief will make the decision if the workspace is visible in the sidebar or not", with
/// heuristics the user shapes). The Chief chooses per spawn; under `auto` the host shows a task that mentions a
/// show word, hides one that mentions a hide word, else shows a task of at least the minimum words. The words
/// listed here add to the built-in ones (optchat-chief `sidebar_choice.rs`). The Chief host reads the keys at each
/// spawn, so a change applies to the next subagent.
nonisolated enum ChiefSidebarSettingsSchema {
    static let modePath = ["chief", "subagentSidebar"]
    static let showWordsPath = ["chief", "subagentSidebarShowWords"]
    static let hideWordsPath = ["chief", "subagentSidebarHideWords"]
    static let minWordsPath = ["chief", "subagentSidebarMinWords"]
    static let keys: Set<String> = Set([modePath, showWordsPath, hideWordsPath, minWordsPath].map { $0.joined(separator: ".") })

    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.chiefSubagents", "Subagents")
        let keywords = ["chief", "subagent", "sidebar", "workspace", "show", "hide", "hidden", "visible"]
        let wordOrPhrase = SettingsText.keyed("settings.placeholder.wordOrPhrase", "Add a word or phrase")
        return [
            SettingDescriptor(
                modePath, section: .home, group: group,
                title: SettingsText.keyed("settings.chief.subagentSidebar", "Subagents in the Sidebar"),
                help: SettingsText.keyed("settings.chief.subagentSidebar.help",
                                         "Automatic lets the Chief decide for each subagent: work you will want to watch or join shows, short errands stay hidden. Always and Never override the Chief."),
                kind: .choice([
                    SettingChoice("auto", SettingsText.keyed("settings.choice.subagentSidebarAuto", "Chief Decides")),
                    SettingChoice("always", SettingsText.keyed("settings.choice.subagentSidebarAlways", "Always")),
                    SettingChoice("never", SettingsText.keyed("settings.choice.subagentSidebarNever", "Never")),
                ]),
                default: .string("auto"), keywords: keywords
            ),
            SettingDescriptor(
                showWordsPath, section: .home, group: group,
                title: SettingsText.keyed("settings.chief.subagentSidebarShowWords", "Show Tasks That Mention"),
                help: SettingsText.keyed("settings.chief.subagentSidebarShowWords.help",
                                         "Words or phrases that show a subagent when the Chief leaves it to these rules. They add to the built-in ones, such as UI, design, screenshots and needs you."),
                kind: .stringList, default: .array([]), keywords: keywords + ["words", "rules"],
                placeholder: wordOrPhrase
            ),
            SettingDescriptor(
                hideWordsPath, section: .home, group: group,
                title: SettingsText.keyed("settings.chief.subagentSidebarHideWords", "Hide Tasks That Mention"),
                help: SettingsText.keyed("settings.chief.subagentSidebarHideWords.help",
                                         "Words or phrases that keep a subagent hidden when the Chief leaves it to these rules. They add to the built-in ones, such as lookup, cleanup and land queue. A show word wins."),
                kind: .stringList, default: .array([]), keywords: keywords + ["words", "rules"],
                placeholder: wordOrPhrase
            ),
            SettingDescriptor(
                minWordsPath, section: .home, group: group,
                title: SettingsText.keyed("settings.chief.subagentSidebarMinWords", "Show Tasks Longer Than"),
                help: SettingsText.keyed("settings.chief.subagentSidebarMinWords.help",
                                         "A task with no show or hide word shows when it has at least this many words, and stays hidden when it is shorter."),
                kind: .number(SettingNumber(0...1000, step: 10, unit: .count)), default: .number(50),
                keywords: keywords + ["length", "words"]
            ),
        ]
    }
}
