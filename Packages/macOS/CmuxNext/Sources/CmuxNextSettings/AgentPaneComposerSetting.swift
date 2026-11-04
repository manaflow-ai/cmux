import CmuxNextDesign

/// The agent pane composer's own keys in cmux.json (the pane reads the same names,
/// webviews/src/agent-session/acpmux/composerSettings.ts):
///
/// ```jsonc
/// "agentPane": { "showContextUsage": true, "composerRing": "context", "showDictation": true, "spellChecking": false, "attachmentView": "inline", "scrollToBottomOnSend": true, "showMachineLoadWarnings": true }
/// ```
///
/// `showContextUsage`: the context usage ring beside the model. The ring's right-click hides it,
/// the composer footer's right-click shows it again. `composerRing`: what that ring shows,
/// `context` (the chat's context window usage; the default) or `planUsage` (the account's plan
/// usage limits, 5-hour and weekly, when the harness reports them); `showContextUsage` still hides
/// or shows the ring either way. Leo, 2026-11-04: "i guess we can turn that into a 5h/weekly usage
/// type thing instead as well for some people". `showDictation`: the dictation mic beside Send
/// in every composer (a chat's and the New Tab page's); its right-click hides it, Settings shows it
/// again. A bad value is the default plus a diagnostic.
/// `spellChecking`: opt-in system spell checking for web and native composers. It is off by default.
/// `attachmentView`: how pictures and files show in every composer and in sent messages, `inline`
/// (each in the text where it was added, as Messages does; the default), `strip` (in a row) or
/// `both` (in the text and in the row, each removable from either; sent messages draw it as
/// `inline`). Only the look: a draft's text, its attachments and their order are the same in all.
/// `scrollToBottomOnSend`: when enabled, sending while reading up jumps to the newest row (the
/// current behavior); when disabled, sending preserves the visible row and offset while new rows
/// arrive below it. A reader at the bottom still follows streaming output.
/// `showMachineLoadWarnings`: the Computer menu adds cached high-load or low-memory details to
/// remote machine rows. It is on by default and does not start another health poller.
/// `newChatsIn`: where a new chat runs when the person picks nothing in its composer, `local`
/// (this Mac, the default) or `cloud` (its first send starts it on the person's own Cloud
/// machine, the page's `cloud.startChat`). The page decides (runLocationDefault.ts); this only
/// carries the value. Leo, 2026-10-31: "whenever i start a chat it should be able to send me to
/// cloud autommatically".
///
/// `reasoningSlider` is not a cmux.json key: the Debug Settings toggle `agent.reasoningSlider`
/// (CmuxNextAgentPane AgentPaneTunables, DEV and NIGHTLY, off by default) sets it, and it rides the
/// same `composer` event, so the reasoning menu draws its stepped slider instead of the levels.
/// `reasoningSliderStyle` carries the Debug Settings visual comparison choice, defaulting to
/// `accent` so the slider's current treatment remains unchanged.
public nonisolated struct AgentPaneComposerSetting: Sendable, Hashable {
    public static let showContextUsagePath = ["agentPane", "showContextUsage"]
    public static let composerRingPath = ["agentPane", "composerRing"]
    public static let showDictationPath = ["agentPane", "showDictation"]
    public static let spellCheckingPath = ["agentPane", "spellChecking"]
    public static let attachmentViewPath = ["agentPane", "attachmentView"]
    public static let scrollToBottomOnSendPath = ["agentPane", "scrollToBottomOnSend"]
    public static let showMachineLoadWarningsPath = ["agentPane", "showMachineLoadWarnings"]
    public static let newChatsInPath = ["agentPane", "newChatsIn"]

    public var showContextUsage = true
    public var composerRing = AgentPaneComposerRing.context
    public var showDictation = true
    public var spellChecking = false
    public var attachmentView = AgentPaneAttachmentView.inline
    public var scrollToBottomOnSend = true
    public var showMachineLoadWarnings = true
    public var newChatsIn = AgentPaneNewChatPlace.local
    /// The Debug Settings opt-in (`agent.reasoningSlider`); never parsed from cmux.json.
    public var reasoningSlider = false
    /// The Debug Settings visual choice (`agent.reasoningSliderStyle`); never parsed from cmux.json.
    public var reasoningSliderStyle = "accent"

    public init() {}

    public static let fallback = AgentPaneComposerSetting()

    /// The page's value (the `composer` host event): `{showContextUsage, composerRing, showDictation, spellChecking, attachmentView, scrollToBottomOnSend, showMachineLoadWarnings, newChatsIn, reasoningSlider, reasoningSliderStyle}`.
    public var pageValue: JSONValue {
        [
            "showContextUsage": .bool(showContextUsage),
            "composerRing": .string(composerRing.rawValue),
            "showDictation": .bool(showDictation),
            "spellChecking": .bool(spellChecking),
            "attachmentView": .string(attachmentView.rawValue),
            "scrollToBottomOnSend": .bool(scrollToBottomOnSend),
            "showMachineLoadWarnings": .bool(showMachineLoadWarnings),
            "newChatsIn": .string(newChatsIn.rawValue),
            "reasoningSlider": .bool(reasoningSlider),
            "reasoningSliderStyle": .string(reasoningSliderStyle)
        ]
    }

    /// Checked against its schema row, so the parser and the Settings window agree.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> AgentPaneComposerSetting {
        var setting = fallback
        for descriptor in AgentPaneComposerSettingsSchema.descriptors {
            guard let value = root.value(at: descriptor.path) else { continue }
            if descriptor.path == attachmentViewPath {
                guard descriptor.accepts(value), let view = value.stringValue.flatMap(AgentPaneAttachmentView.init(rawValue:)) else {
                    diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id, message: OmnibarSettingsSchema.expectation(descriptor)))
                    continue
                }
                setting.attachmentView = view
                continue
            }
            if descriptor.path == composerRingPath {
                guard descriptor.accepts(value), let ring = value.stringValue.flatMap(AgentPaneComposerRing.init(rawValue:)) else {
                    diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id, message: OmnibarSettingsSchema.expectation(descriptor)))
                    continue
                }
                setting.composerRing = ring
                continue
            }
            if descriptor.path == newChatsInPath {
                guard descriptor.accepts(value), let place = value.stringValue.flatMap(AgentPaneNewChatPlace.init(rawValue:)) else {
                    diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id, message: OmnibarSettingsSchema.expectation(descriptor)))
                    continue
                }
                setting.newChatsIn = place
                continue
            }
            guard descriptor.accepts(value), let flag = value.boolValue else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id, message: OmnibarSettingsSchema.expectation(descriptor)))
                continue
            }
            if descriptor.path == showContextUsagePath { setting.showContextUsage = flag }
            if descriptor.path == showDictationPath { setting.showDictation = flag }
            if descriptor.path == spellCheckingPath { setting.spellChecking = flag }
            if descriptor.path == scrollToBottomOnSendPath { setting.scrollToBottomOnSend = flag }
            if descriptor.path == showMachineLoadWarningsPath { setting.showMachineLoadWarnings = flag }
        }
        return setting
    }
}

/// How the composer and sent messages show attachments (`agentPane.attachmentView`).
public nonisolated enum AgentPaneAttachmentView: String, Sendable, Hashable, CaseIterable {
    /// Each attachment in the text where it was added, as Messages does.
    case inline
    /// The attachments together in a row.
    case strip
    /// In the text and in the row too, so every attachment shows in one place with its remove
    /// (Leo, 2026-10-24: "ALSO show the top displayed attachments alongside the inline attachments").
    case both
}

/// What the composer's ring shows (`agentPane.composerRing`).
public nonisolated enum AgentPaneComposerRing: String, Sendable, Hashable, CaseIterable {
    /// How much of its context window the chat has used (the ring as it always was).
    case context
    /// The account's plan usage limits (5-hour and weekly), when the harness reports them.
    case planUsage
}

/// Where a new chat runs when its composer picks nothing (`agentPane.newChatsIn`).
public nonisolated enum AgentPaneNewChatPlace: String, Sendable, Hashable, CaseIterable {
    /// This Mac, as before.
    case local
    /// The person's own Cloud machine (a free one of theirs, else a new one).
    case cloud
}

/// The composer's rows (General > Agent Chat, next to the edited-files card's).
nonisolated enum AgentPaneComposerSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.agentChat", "Agent Chat")
        return [
            SettingDescriptor(
                AgentPaneComposerSetting.showContextUsagePath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.showContextUsage", "Show Context Usage"),
                help: SettingsText.keyed("settings.agentPane.showContextUsage.help",
                                         "The ring beside the model that fills as the chat uses its context window."),
                kind: .toggle, default: .bool(AgentPaneComposerSetting.fallback.showContextUsage),
                keywords: ["context", "usage", "tokens", "window", "ring", "composer", "agent"]
            ),
            SettingDescriptor(
                AgentPaneComposerSetting.composerRingPath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.composerRing", "Composer Ring"),
                help: SettingsText.keyed("settings.agentPane.composerRing.help",
                                         "What the ring at the end of the composer shows: the chat's context usage, or your plan's usage limits (5-hour and weekly) when the harness reports them."),
                kind: .choice([
                    SettingChoice(AgentPaneComposerRing.context.rawValue,
                                  SettingsText.keyed("settings.choice.composerRingContext", "Context")),
                    SettingChoice(AgentPaneComposerRing.planUsage.rawValue,
                                  SettingsText.keyed("settings.choice.composerRingPlanUsage", "Plan Usage")),
                ]),
                default: .string(AgentPaneComposerSetting.fallback.composerRing.rawValue),
                keywords: ["context", "usage", "plan", "limit", "limits", "5-hour", "weekly", "rate", "quota", "ring", "composer", "agent"]
            ),
            SettingDescriptor(
                AgentPaneComposerSetting.showDictationPath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.showDictation", "Show Dictation Button"),
                help: SettingsText.keyed("settings.agentPane.showDictation.help",
                                         "The microphone beside Send in every composer, including the New Tab page."),
                kind: .toggle, default: .bool(AgentPaneComposerSetting.fallback.showDictation),
                keywords: ["dictation", "microphone", "mic", "voice", "speech", "composer", "agent", "new tab"]
            ),
            SettingDescriptor(
                AgentPaneComposerSetting.spellCheckingPath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.spellChecking", "Check Spelling While Typing"),
                help: SettingsText.keyed("settings.agentPane.spellChecking.help",
                                         "Underlines misspellings and offers system suggestions in the composer."),
                kind: .toggle, default: .bool(AgentPaneComposerSetting.fallback.spellChecking),
                keywords: ["spell", "spelling", "grammar", "misspelling", "composer", "suggestions", "typing"]
            ),
            SettingDescriptor(
                AgentPaneComposerSetting.attachmentViewPath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.attachmentView", "Attachment View"),
                help: SettingsText.keyed("settings.agentPane.attachmentView.help",
                                         "How pictures and files show in the composer and in sent messages. Inline puts each one in the text where you added it; Strip shows them in a row. The message and its order stay the same."),
                kind: .choice([
                    SettingChoice(AgentPaneAttachmentView.inline.rawValue,
                                  SettingsText.keyed("settings.choice.agentChatAttachmentInline", "Inline")),
                    SettingChoice(AgentPaneAttachmentView.strip.rawValue,
                                  SettingsText.keyed("settings.choice.agentChatAttachmentStrip", "Strip")),
                    SettingChoice(AgentPaneAttachmentView.both.rawValue,
                                  SettingsText.keyed("settings.choice.agentChatAttachmentBoth", "Inline and Strip")),
                ]),
                default: .string(AgentPaneComposerSetting.fallback.attachmentView.rawValue),
                keywords: ["attachment", "attachments", "image", "picture", "file", "inline", "strip", "both", "composer", "messages"]
            ),
            SettingDescriptor(
                AgentPaneComposerSetting.scrollToBottomOnSendPath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.scrollToBottomOnSend", "Scroll to Bottom When I Send"),
                help: SettingsText.keyed("settings.agentPane.scrollToBottomOnSend.help",
                                         "When off, sending while you are reading up keeps your place and shows new messages below."),
                kind: .toggle, default: .bool(AgentPaneComposerSetting.fallback.scrollToBottomOnSend),
                keywords: ["scroll", "bottom", "send", "message", "chat", "latest", "follow"]
            ),
            SettingDescriptor(
                AgentPaneComposerSetting.showMachineLoadWarningsPath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.showMachineLoadWarnings", "Show Machine Load Warnings"),
                help: SettingsText.keyed("settings.agentPane.showMachineLoadWarnings.help",
                                         "Shows a warning when a remote machine is at its CPU or memory budget in the Computer menu."),
                kind: .toggle, default: .bool(AgentPaneComposerSetting.fallback.showMachineLoadWarnings),
                keywords: ["machine", "load", "memory", "cpu", "warning", "computer", "composer", "agent"]
            ),
            SettingDescriptor(
                AgentPaneComposerSetting.newChatsInPath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.newChatsIn", "Start New Chats In"),
                help: SettingsText.keyed("settings.agentPane.newChatsIn.help",
                                         "Where a new chat runs. Cloud starts it on your own Cloud machine, with your project copied there. The new chat's composer can change it for that chat."),
                kind: .choice([
                    SettingChoice(AgentPaneNewChatPlace.local.rawValue,
                                  SettingsText.keyed("settings.choice.newChatsInLocal", "This Mac")),
                    SettingChoice(AgentPaneNewChatPlace.cloud.rawValue,
                                  SettingsText.keyed("settings.choice.newChatsInCloud", "Cloud")),
                ]),
                default: .string(AgentPaneComposerSetting.fallback.newChatsIn.rawValue),
                keywords: ["cloud", "new chat", "start", "machine", "vm", "remote", "this mac", "local", "run"]
            ),
        ]
    }

    /// The visual composer choices agents may change; send behavior remains a user-only choice.
    static var agentSettableKeys: Set<String> {
        Set([AgentPaneComposerSetting.showContextUsagePath,
             AgentPaneComposerSetting.composerRingPath,
             AgentPaneComposerSetting.showDictationPath,
             AgentPaneComposerSetting.spellCheckingPath,
             AgentPaneComposerSetting.attachmentViewPath,
             AgentPaneComposerSetting.showMachineLoadWarningsPath].map { $0.joined(separator: ".") })
    }
}
