#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The Settings > Voice Mode section. Reads ``MobileVoiceSettings`` from the
/// environment and renders nothing when it is absent (previews, hosts
/// without the app composition root).
struct MobileVoiceSettingsSection: View {
    @Environment(MobileVoiceSettings.self) private var voiceSettings: MobileVoiceSettings?

    var body: some View {
        if let voiceSettings {
            MobileVoiceSettingsSectionContent(settings: voiceSettings)
            if voiceSettings.voiceModeEnabled {
                MobileVoicePermissionsSectionContent(settings: voiceSettings)
            }
        }
    }
}

/// Separate section so the bypass switch carries its own warning footer.
private struct MobileVoicePermissionsSectionContent: View {
    @Bindable var settings: MobileVoiceSettings

    var body: some View {
        Section {
            Toggle(isOn: $settings.orchestratorBypassPermissions) {
                Text(L10n.string(
                    "mobile.voice.settings.bypass",
                    defaultValue: "Bypass All Permissions"
                ))
            }
            .tint(.red)
            .accessibilityIdentifier("MobileSettingsVoiceBypassToggle")
        } footer: {
            Text(L10n.string(
                "mobile.voice.settings.bypassFooter",
                defaultValue: """
                The voice assistant acts on your workspaces immediately, \
                including destructive actions like closing a workspace, \
                without the on-screen approval card.
                """
            ))
        }
    }
}

private struct MobileVoiceSettingsSectionContent: View {
    @Bindable var settings: MobileVoiceSettings

    var body: some View {
        Section {
            Toggle(isOn: $settings.voiceModeEnabled) {
                Text(L10n.string("mobile.voice.settings.enabled", defaultValue: "Voice Mode"))
            }
            .accessibilityIdentifier("MobileSettingsVoiceModeToggle")

            if settings.voiceModeEnabled {
                Picker(selection: $settings.voiceName) {
                    ForEach(MobileVoiceSettings.availableVoices, id: \.self) { voice in
                        Text(voice.capitalized).tag(voice)
                    }
                } label: {
                    Text(L10n.string("mobile.voice.settings.voice", defaultValue: "Voice"))
                }
                .accessibilityIdentifier("MobileSettingsVoiceNamePicker")

                Toggle(isOn: $settings.speakAgentReplies) {
                    Text(L10n.string(
                        "mobile.voice.settings.speakReplies",
                        defaultValue: "Speak Agent Replies"
                    ))
                }
                .accessibilityIdentifier("MobileSettingsVoiceSpeakRepliesToggle")

                if settings.speakAgentReplies {
                    Toggle(isOn: $settings.speakCodeBlocks) {
                        Text(L10n.string(
                            "mobile.voice.settings.speakCode",
                            defaultValue: "Read Short Code Blocks Aloud"
                        ))
                    }
                    .accessibilityIdentifier("MobileSettingsVoiceSpeakCodeToggle")

                    Toggle(isOn: $settings.speakToolActivity) {
                        Text(L10n.string(
                            "mobile.voice.settings.speakTools",
                            defaultValue: "Describe Tool Activity"
                        ))
                    }
                    .accessibilityIdentifier("MobileSettingsVoiceSpeakToolsToggle")

                    Picker(selection: $settings.spokenReplyLength) {
                        Text(L10n.string(
                            "mobile.voice.settings.replyLength.short",
                            defaultValue: "Short"
                        ))
                        .tag(MobileVoiceSettings.SpokenReplyLength.short)
                        Text(L10n.string(
                            "mobile.voice.settings.replyLength.medium",
                            defaultValue: "Medium"
                        ))
                        .tag(MobileVoiceSettings.SpokenReplyLength.medium)
                        Text(L10n.string(
                            "mobile.voice.settings.replyLength.long",
                            defaultValue: "Long"
                        ))
                        .tag(MobileVoiceSettings.SpokenReplyLength.long)
                    } label: {
                        Text(L10n.string(
                            "mobile.voice.settings.replyLength",
                            defaultValue: "Spoken Reply Length"
                        ))
                    }
                    .accessibilityIdentifier("MobileSettingsVoiceReplyLengthPicker")
                }

                SecureField(
                    L10n.string(
                        "mobile.voice.settings.apiKeyPlaceholder",
                        defaultValue: "OpenAI API Key"
                    ),
                    text: $settings.userOpenAIAPIKey
                )
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("MobileSettingsVoiceAPIKeyField")
            }
        } header: {
            Text(L10n.string("mobile.voice.settings.section", defaultValue: "Voice Mode"))
        } footer: {
            Text(L10n.string(
                "mobile.voice.settings.footer",
                defaultValue: """
                Talk to your agents with GPT-Live. Code blocks, diffs, and \
                tables are summarized instead of read aloud. Voice mode uses \
                your own OpenAI API key, stored only in this device's \
                keychain and sent nowhere except to OpenAI.
                """
            ))
        }
    }
}
#endif
