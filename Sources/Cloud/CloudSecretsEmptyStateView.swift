import CmuxCloud
import CmuxFoundation
import SwiftUI

/// A vault with nothing in it: what a key here does, and the three things
/// most people do first. Anthropic is the default action; Import .env… also
/// pastes from the clipboard in its menu, and the footer's Add (⌘N) takes any
/// other name. The sheet header carries the only key icon.
struct CloudSecretsEmptyStateView: View {
    let onAddPreset: (String) -> Void
    let onImport: () -> Void
    var onPaste: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
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
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("CloudSecretsEmpty.addAnthropic")
                Button(String(localized: "cloudSecrets.empty.addOpenAI", defaultValue: "Add OpenAI Key")) {
                    onAddPreset("OPENAI_API_KEY")
                }
                .accessibilityIdentifier("CloudSecretsEmpty.addOpenAI")
                Menu {
                    Button(String(localized: "cloudSecrets.import.chooseFile", defaultValue: "Choose File\u{2026}"), action: onImport)
                    Button(String(localized: "cloudSecrets.import.paste.menu", defaultValue: "Paste from Clipboard"), action: onPaste)
                        .accessibilityIdentifier("CloudSecretsEmpty.paste")
                } label: {
                    Text(String(localized: "cloudSecrets.empty.import", defaultValue: "Import .env…"))
                } primaryAction: {
                    onImport()
                }
                .fixedSize()
                .accessibilityIdentifier("CloudSecretsEmpty.import")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CloudSecretsEmpty")
    }
}
