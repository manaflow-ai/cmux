import SwiftUI

/// SwiftUI content for a native Subrouter pane.
struct SubrouterPanelView: View {
    let panel: SubrouterPanel
    let onRequestPanelFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SubrouterPanelHeader()
            Divider()
            SubrouterAccountList(
                accounts: panel.model.accounts,
                isLoading: panel.model.isLoading
            )
            Divider()
            SubrouterAddCodexSection(
                isAdding: panel.model.isAddingCodexAccount,
                didAdd: panel.model.didAddCodexAccount,
                failure: panel.model.failure,
                onAdd: {
                    Task { await panel.model.addCodexAccount() }
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Terminal panels remain hosted for fast tab switches, so this native
        // pane must paint an opaque surface instead of inheriting the window's
        // translucent material and revealing the inactive terminal below it.
        .background(Color(nsColor: GhosttyApp.shared.defaultBackgroundColor.withAlphaComponent(1)))
        .contentShape(Rectangle())
        .onTapGesture { onRequestPanelFocus() }
        .task { await panel.model.load() }
        .accessibilityIdentifier("SubrouterPane")
    }
}

private struct SubrouterPanelHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                String(localized: "subrouterPane.title", defaultValue: "Subrouter"),
                systemImage: "point.3.connected.trianglepath.dotted"
            )
            .font(.headline)
            Text(String(
                localized: "subrouterPane.description",
                defaultValue: "Manage the accounts used by the bundled Subrouter."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SubrouterAccountList: View {
    let accounts: [SubrouterAccount]
    let isLoading: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "subrouterPane.accounts.title", defaultValue: "Connected accounts"))
                    .font(.subheadline.weight(.semibold))
                if isLoading && accounts.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else if accounts.isEmpty {
                    Text(String(
                        localized: "subrouterPane.accounts.empty",
                        defaultValue: "No provider accounts are connected yet."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                } else {
                    ForEach(accounts) { account in
                        SubrouterAccountRow(account: account)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SubrouterAccountRow: View {
    let account: SubrouterAccount

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.provider == "codex" ? "brain.head.profile" : "key.fill")
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(providerName)
                    .font(.subheadline.weight(.medium))
                Text(account.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(account.authMode.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var providerName: String {
        switch account.provider {
        case "codex" where account.authMode == "oauth":
            return String(localized: "subrouterPane.provider.codex", defaultValue: "Codex OAuth")
        case "claude":
            return String(localized: "subrouterPane.provider.claude", defaultValue: "Claude OAuth")
        case "anthropic" where account.authMode == "apikey":
            return String(localized: "subrouterPane.provider.anthropicKey", defaultValue: "Anthropic API key")
        case "openai" where account.authMode == "apikey",
             "codex" where account.authMode == "apikey":
            return String(localized: "subrouterPane.provider.openAIKey", defaultValue: "OpenAI API key")
        default:
            return String(localized: "subrouterPane.provider.unknown", defaultValue: "Provider account")
        }
    }
}

private struct SubrouterAddCodexSection: View {
    let isAdding: Bool
    let didAdd: Bool
    let failure: SubrouterPaneFailure?
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(
                localized: "subrouterPane.addCodex.description",
                defaultValue: "Import the Codex account currently signed in on this Mac."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            Button(action: onAdd) {
                if isAdding {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(isAdding
                    ? String(localized: "subrouterPane.addCodex.adding", defaultValue: "Adding Codex account…")
                    : String(localized: "subrouterPane.addCodex.button", defaultValue: "Add Codex Account"))
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAdding)
            .accessibilityIdentifier("SubrouterPane.AddCodexAccount")
            if didAdd {
                Label(
                    String(localized: "subrouterPane.addCodex.success", defaultValue: "Codex account added."),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            }
            if let failure {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
