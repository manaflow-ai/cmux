#if os(iOS)
import CmuxMobileDesign
import CmuxMobileRealtime
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// Settings → Chief Calls: the user's OpenAI API key (live calls with Chief
/// run on the user's own OpenAI account), the voice model and Chief's voice.
///
/// Call Chief opens this page when no key is set. A pasted key is checked
/// with OpenAI before it is kept; a refused key is never stored. The key is
/// kept in this iPhone's Keychain for the signed-in account only and is shown
/// masked; Replace and Remove are the only ways to change it.
struct ChiefCallsPage: View {
    let keys: OpenAIKeyModel
    let preferences: VoiceCallPreferences
    /// Starts a call (the shell's launcher); nil where calls can't start.
    let callChief: (() -> Void)?
    @State private var draft = ""
    @State private var replacing = false
    @State private var confirmsRemove = false
    @FocusState private var fieldFocused: Bool

    private var editing: Bool { !keys.hasKey || replacing }

    var body: some View {
        @Bindable var preferences = preferences
        List {
            Section {
                if editing {
                    keyField
                } else {
                    storedKeyRows
                }
                if let check = keys.check, !keys.isChecking {
                    CheckLine(check: check, hasKey: keys.hasKey)
                }
            } header: {
                Text("OpenAI API key")
            } footer: {
                Text("Calls go from this iPhone straight to OpenAI with your key, and OpenAI bills your account. The key stays in this iPhone’s Keychain, for this cmux account only.")
            }

            if keys.hasKey, !replacing, let callChief {
                Section {
                    Button {
                        callChief()
                    } label: {
                        Label("Call Chief", systemImage: "phone.fill")
                            .font(theme.type.rowTitle)
                            .foregroundStyle(.green)
                    }
                    .accessibilityIdentifier("settings.chiefCalls.call")
                }
            }

            Section {
                Picker(selection: $preferences.modelID) {
                    ForEach(VoiceCallModelChoice.all) { model in
                        VStack(alignment: .leading) {
                            Text(model.title)
                            Text(model.detail).font(.footnote).foregroundStyle(theme.colors.label2)
                        }
                        .tag(model.id)
                    }
                } label: {
                    SettingsLabel("Model", symbol: "cpu")
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("settings.chiefCalls.model")
                Picker(selection: $preferences.voiceID) {
                    ForEach(VoiceCallVoice.all) { voice in
                        Text(voice.title).tag(voice.id)
                    }
                } label: {
                    SettingsLabel("Voice", symbol: "waveform")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.chiefCalls.voice")
            } header: {
                Text("Voice")
            } footer: {
                Text("Changes apply to the next call. Marin and Cedar sound most natural.")
            }

            Section {
                LinkRow("Get an API key", symbol: "key", url: "https://platform.openai.com/api-keys")
                LinkRow("Usage and billing", symbol: "chart.bar", url: "https://platform.openai.com/usage")
            }
        }
        .settingsPage("Chief Calls")
        .confirmationDialog("Remove your OpenAI API key?", isPresented: $confirmsRemove, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) { keys.remove() }
        } message: {
            Text("Chief calls stop working on this iPhone until you add a key again.")
        }
        .accessibilityIdentifier("settings.chiefCalls")
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SecureField("sk-…", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .font(.body.monospaced())
                    .accessibilityLabel("OpenAI API key")
                    .accessibilityIdentifier("settings.chiefCalls.keyField")
                Button {
                    if let pasted = UIPasteboard.general.string { draft = pasted }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Paste")
                .accessibilityIdentifier("settings.chiefCalls.paste")
            }
            HStack {
                if replacing {
                    Button("Cancel") {
                        replacing = false
                        draft = ""
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                if keys.isChecking {
                    ProgressView()
                        .accessibilityLabel("Checking with OpenAI")
                } else {
                    Button("Save Key", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(!keys.isPlausible(draft))
                        .accessibilityIdentifier("settings.chiefCalls.save")
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var storedKeyRows: some View {
        HStack {
            SettingsLabel("API key", symbol: "key.fill")
            Spacer()
            Text(keys.maskedKey ?? "")
                .font(.body.monospaced())
                .foregroundStyle(theme.colors.label2)
                .accessibilityIdentifier("settings.chiefCalls.masked")
        }
        Button {
            Task { await keys.recheck(model: preferences.modelID) }
        } label: {
            HStack {
                SettingsLabel("Check Key", symbol: "checkmark.shield")
                if keys.isChecking {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(keys.isChecking)
        .accessibilityIdentifier("settings.chiefCalls.check")
        Button {
            replacing = true
            fieldFocused = true
        } label: {
            SettingsLabel("Replace Key", symbol: "arrow.triangle.2.circlepath")
        }
        .accessibilityIdentifier("settings.chiefCalls.replace")
        Button(role: .destructive) {
            confirmsRemove = true
        } label: {
            Label {
                Text("Remove Key").font(theme.type.rowTitle)
            } icon: {
                SettingsIcon("trash")
            }
            .foregroundStyle(theme.colors.danger)
        }
        .accessibilityIdentifier("settings.chiefCalls.remove")
    }

    private func save() {
        guard keys.isPlausible(draft), !keys.isChecking else { return }
        let candidate = draft
        Task {
            let outcome = await keys.add(candidate, model: preferences.modelID)
            if keys.hasKey, outcome != .rejected, outcome != .malformed {
                draft = ""
                replacing = false
            }
        }
    }
}

/// What OpenAI said about the key, under the key rows.
private struct CheckLine: View {
    let check: OpenAIKeyCheck
    let hasKey: Bool

    var body: some View {
        Label {
            Text(text).font(.footnote)
        } icon: {
            Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        }
        .foregroundStyle(good ? Color.green : Color.orange)
        .accessibilityIdentifier("settings.chiefCalls.checkResult")
    }

    private var good: Bool { check == .valid }

    private var text: String {
        switch check {
        case .valid: String(localized: "Key works. Chief calls are ready.")
        case .malformed: String(localized: "That isn’t an OpenAI API key. Keys start with “sk-”.")
        case .rejected: String(localized: "OpenAI refused this key. Check that it’s active and copied in full.")
        case .modelUnavailable: String(localized: "The key works, but its project can’t use this voice model. Allow it in your OpenAI project, or pick another model.")
        case .quota: String(localized: "The key works, but the account is out of credit or over its rate limit.")
        case let .unreachable(reason):
            hasKey ? String(localized: "Couldn’t reach OpenAI to check the key (\(reason)). It’s saved; calls will say if it doesn’t work.")
                : String(localized: "Couldn’t reach OpenAI (\(reason)).")
        case .notSaved: String(localized: "The key couldn’t be saved to the Keychain.")
        }
    }
}
#endif
