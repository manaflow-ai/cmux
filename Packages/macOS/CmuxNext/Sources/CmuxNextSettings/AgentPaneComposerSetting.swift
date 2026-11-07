// The paths, defaults and the AgentPaneComposerRing, AgentPaneAttachmentView and AgentPaneNewChatPlace
// enums are generated from schemas/settings/source/agent-pane-composer.json
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
