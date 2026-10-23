/// Settings > Chief > Reactions (a416): whether a tapback on a Chief message can start a turn, and the cheap
/// classifier that decides it. One group of `SettingsSchema` rows (its own type: the schema type's line
/// budget is per type). The Chief host reads the keys at each decision; a Chief's engine.json overrides them.
nonisolated enum ChiefReactionSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.chiefReactions", "Reactions")
        let keywords = ["chief", "reaction", "tapback", "wake", "classifier", "turn", "typing"]
        return [
            SettingDescriptor(
                ChiefReactionSettings.canWakePath, section: .home, group: group,
                title: SettingsText.keyed("settings.chief.reactionsCanWake", "Reactions Can Wake the Chief"),
                help: SettingsText.keyed("settings.chief.reactionsCanWake.help",
                                         "A reaction you put on a Chief message can start a turn when it asks for one, such as a question mark on a question or a thumbs down on a plan. A cheap model decides first, so a reaction that needs no answer never shows the typing dots. Off, reactions are only noted."),
                kind: .toggle, default: .bool(ChiefReactionSettings.fallback.canWake), keywords: keywords
            ),
            SettingDescriptor(
                ChiefReactionSettings.harnessPath, section: .home, group: group,
                title: SettingsText.keyed("settings.chief.reactionClassifier.harness", "Reaction Classifier Harness"),
                help: SettingsText.keyed("settings.chief.reactionClassifier.harness.help",
                                         "The agent harness the reaction classifier runs on, for example claude or codex. Empty uses the Chief's Claude route."),
                kind: .text, default: .string(ChiefReactionSettings.fallback.harness), keywords: keywords + ["harness"]
            ),
            SettingDescriptor(
                ChiefReactionSettings.modelPath, section: .home, group: group,
                title: SettingsText.keyed("settings.chief.reactionClassifier.model", "Reaction Classifier Model"),
                help: SettingsText.keyed("settings.chief.reactionClassifier.model.help",
                                         "The model that decides whether a reaction starts a turn. Claude Haiku by default: it is fast and cheap."),
                kind: .text, default: .string(ChiefReactionSettings.fallback.model), keywords: keywords + ["model", "haiku"]
            ),
            SettingDescriptor(
                ChiefReactionSettings.promptPath, section: .home, group: group,
                title: SettingsText.keyed("settings.chief.reactionClassifier.prompt", "Reaction Classifier Instructions"),
                help: SettingsText.keyed("settings.chief.reactionClassifier.prompt.help",
                                         "What the classifier is told when it decides. Empty uses the built-in instructions."),
                kind: .text, default: .string(ChiefReactionSettings.fallback.prompt), keywords: keywords + ["prompt", "instructions"]
            ),
        ]
    }
}
