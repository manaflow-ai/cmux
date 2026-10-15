import CmuxCloud
import CmuxFoundation
import SwiftUI

/// A vault with nothing in it: what a key here does, and the three things
/// most people do first. Paste and a blank add stay one click away below.
struct CloudSecretsEmptyStateView: View {
    let onAddPreset: (String) -> Void
    let onImport: () -> Void
    var onPaste: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(String(localized: "cloudSecrets.empty.title", defaultValue: "Add your first API key"))
                    .cmuxFont(size: 14, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                Text(String(
                    localized: "cloudSecrets.empty.body",
                    defaultValue: "Claude Code, Codex, and other agents on your Cloud machines use your keys automatically."
                ))
                .cmuxFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(String(localized: "cloudSecrets.empty.addAnthropic", defaultValue: "Add Anthropic Key")) {
                    onAddPreset("ANTHROPIC_API_KEY")
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("CloudSecretsEmpty.addAnthropic")
                Button(String(localized: "cloudSecrets.empty.addOpenAI", defaultValue: "Add OpenAI Key")) {
                    onAddPreset("OPENAI_API_KEY")
                }
                .accessibilityIdentifier("CloudSecretsEmpty.addOpenAI")
                Button(String(localized: "cloudSecrets.empty.import", defaultValue: "Import .env…"), action: onImport)
                    .accessibilityIdentifier("CloudSecretsEmpty.import")
            }
            .controlSize(.large)
            HStack(spacing: 14) {
                Button(String(localized: "cloudSecrets.empty.addOther", defaultValue: "Add another variable")) {
                    onAddPreset("")
                }
                .keyboardShortcut("n", modifiers: .command)
                Button(String(localized: "cloudSecrets.import.paste", defaultValue: "Paste .env"), action: onPaste)
            }
            .buttonStyle(.link)
            .cmuxFont(size: 11)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CloudSecretsEmpty")
    }
}
