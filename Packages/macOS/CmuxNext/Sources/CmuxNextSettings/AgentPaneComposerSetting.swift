// The paths, defaults and the AgentPaneComposerRing, AgentPaneAttachmentView, AgentPaneNewChatPlace and
// AgentPaneDictationSource enums are generated from schemas/settings/source/agent-pane-composer.json
// (Schema/SettingsSchema+AgentPaneComposer*.generated.swift).

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
/// `dictationSource`: what that mic dictates with, `cmux` (cmux's own dictation; the default) or the
/// dictation app the person already uses: `macos` (macOS Dictation), `chatgpt`, `claude`, `gemini`,
/// `wisprFlow` or `superwhisper`, whose shortcut the mic then sends (design/composer-dictation.md).
/// `dictationShortcut`: the chord the mic sends for an app source, such as `ctrl+opt+space`, when
/// the person bound the app to one other than its default; empty (the default) uses the app's.
/// Leo, 2026-11-07: "you can optionally have it be like, oh, you use Claude's thing, or ChatGPT's
/// thing ... Or, like, maybe you can map the button to that thing, perhaps?"
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
    public var showContextUsage = Self.showContextUsageDefault
    public var composerRing = Self.composerRingDefault
    public var showDictation = Self.showDictationDefault
    public var dictationSource = Self.dictationSourceDefault
    public var dictationShortcut = Self.dictationShortcutDefault
    public var spellChecking = Self.spellCheckingDefault
    public var attachmentView = Self.attachmentViewDefault
    public var scrollToBottomOnSend = Self.scrollToBottomOnSendDefault
    public var showMachineLoadWarnings = Self.showMachineLoadWarningsDefault
    public var newChatsIn = Self.newChatsInDefault
    /// The Debug Settings opt-in (`agent.reasoningSlider`); never parsed from cmux.json.
    public var reasoningSlider = false
    /// The Debug Settings visual choice (`agent.reasoningSliderStyle`); never parsed from cmux.json.
    public var reasoningSliderStyle = "accent"

    public init() {}

    public static let fallback = AgentPaneComposerSetting()

    /// The page's value (the `composer` host event): `{showContextUsage, composerRing, showDictation, dictationSource, dictationShortcut, spellChecking, attachmentView, scrollToBottomOnSend, showMachineLoadWarnings, newChatsIn, reasoningSlider, reasoningSliderStyle}`.
    public var pageValue: JSONValue {
        [
            "showContextUsage": .bool(showContextUsage),
            "composerRing": .string(composerRing.rawValue),
            "showDictation": .bool(showDictation),
            "dictationSource": .string(dictationSource.rawValue),
            "dictationShortcut": .string(dictationShortcut),
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
            if descriptor.path == dictationSourcePath {
                guard descriptor.accepts(value), let source = value.stringValue.flatMap(AgentPaneDictationSource.init(rawValue:)) else {
                    diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id, message: OmnibarSettingsSchema.expectation(descriptor)))
                    continue
                }
                setting.dictationSource = source
                continue
            }
            if descriptor.path == dictationShortcutPath {
                guard descriptor.accepts(value), let shortcut = value.stringValue else {
                    diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id, message: OmnibarSettingsSchema.expectation(descriptor)))
                    continue
                }
                // A chord that does not parse is kept, so the mic refuses it (`dictation.bad_shortcut`)
                // instead of sending the app's default the person replaced.
                if !shortcut.isEmpty, AgentPaneDictationShortcut(shortcut) == nil {
                    diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id, message: OmnibarSettingsSchema.expectation(descriptor)))
                }
                setting.dictationShortcut = shortcut
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

/// A chord the mic sends for an app source (`agentPane.dictationShortcut`): modifiers and one key,
/// joined with `+`, such as `ctrl+opt+space` or `cmd+shift+d`. At least one of cmd, ctrl, opt; a
/// bare key or shift alone would type into the composer instead of reaching the app.
public nonisolated struct AgentPaneDictationShortcut: Sendable, Hashable {
    public nonisolated struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)
    }

    public let modifiers: Modifiers
    /// The key's name: a letter, a digit, `space`, `return`, `tab` or `f1`...`f19`.
    public let key: String

    public init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let key = parts.last, Self.isKey(key) else { return nil }
        var modifiers = Modifiers()
        for part in parts.dropLast() {
            let modifier: Modifiers
            switch part {
            case "cmd", "command": modifier = .command
            case "ctrl", "control": modifier = .control
            case "opt", "option", "alt": modifier = .option
            case "shift": modifier = .shift
            default: return nil
            }
            guard !modifiers.contains(modifier) else { return nil }
            modifiers.insert(modifier)
        }
        guard !modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        (self.modifiers, self.key) = (modifiers, key)
    }

    static func isKey(_ key: String) -> Bool {
        if ["space", "return", "tab"].contains(key) { return true }
        if key.count == 1, let character = key.first, character.isASCII, character.isLetter || character.isNumber { return true }
        if key.hasPrefix("f"), let number = Int(key.dropFirst()), (1...19).contains(number) { return true }
        return false
    }
}
