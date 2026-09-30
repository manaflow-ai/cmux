import AppKit
import CmuxCloud
import CmuxFoundation
import SwiftUI

/// Displays CodeRouter accounts and team usage below the Cloud tree.
struct CoderouterAccountsPanel: View {
    let teamID: String?
    let chromeBackgroundColor: NSColor
    @State var model: CoderouterAccountsPanelModel
    @State var isAddPresented = false
    @State var accountToRemove: CoderouterAccountsPanelModel.Account?
    @State var operationError: String?

    init(
        teamID: String?,
        chromeBackgroundColor: NSColor,
        model: CoderouterAccountsPanelModel? = nil
    ) {
        self.teamID = teamID
        self.chromeBackgroundColor = chromeBackgroundColor
        _model = State(initialValue: model ?? CoderouterAccountsPanelModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    usageSection
                    accountsSection
                }
                .padding(.bottom, 8)
            }
        }
        .background(Color(nsColor: chromeBackgroundColor).opacity(0.18))
        .accessibilityIdentifier("CoderouterSection")
        .task(id: teamID ?? "coderouter-no-team") {
            model.load(teamID: teamID)
        }
        .onDisappear {
            model.cancel()
        }
        .sheet(isPresented: $isAddPresented) {
            CoderouterAddAccountSheet(model: model)
        }
        .confirmationDialog(
            String(localized: "coderouter.sidebar.remove.title", defaultValue: "Remove this account?"),
            isPresented: Binding(
                get: { accountToRemove != nil },
                set: { if !$0 { accountToRemove = nil } }
            ),
            presenting: accountToRemove
        ) { account in
            Button(String(localized: "coderouter.sidebar.remove.action", defaultValue: "Remove"), role: .destructive) {
                remove(account)
            }
            Button(String(localized: "coderouter.sidebar.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: { account in
            Text(String(
                format: String(localized: "coderouter.sidebar.remove.message", defaultValue: "Remove %@ from this team?"),
                Self.accountDisplayName(account)
            ))
        }
        .alert(
            String(localized: "coderouter.sidebar.error.title", defaultValue: "CodeRouter action failed"),
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            ),
            presenting: operationError
        ) { _ in
            Button(String(localized: "coderouter.sidebar.ok", defaultValue: "OK"), role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "cpu")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(String(localized: "coderouter.sidebar.title", defaultValue: "CodeRouter"))
                .cmuxFont(size: 12, weight: .medium)
                .foregroundStyle(.primary)
            if !model.accounts.isEmpty {
                Text(Self.countLabel(model.accounts.count))
                    .cmuxFont(size: 11, design: .monospaced, monospacedDigit: true)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.state == .loading || model.isMutating)
            .help(String(localized: "coderouter.sidebar.refresh", defaultValue: "Refresh CodeRouter"))
            .accessibilityLabel(String(localized: "coderouter.sidebar.refresh", defaultValue: "Refresh CodeRouter"))
            Button {
                isAddPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(teamID == nil || model.isMutating || !ManagedAICredentialUploadPolicy.isEnabled)
            .help(String(localized: "coderouter.sidebar.add", defaultValue: "Add CodeRouter account"))
            .accessibilityLabel(String(localized: "coderouter.sidebar.add", defaultValue: "Add CodeRouter account"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: chromeBackgroundColor).opacity(0.35))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CoderouterSectionHeader")
    }


    static func accountDisplayName(_ account: CoderouterAccountsPanelModel.Account) -> String {
        switch account {
        case .claude(let value):
            return value.label.isEmpty ? claudeProviderLabel(value.kind) : value.label
        case .shared(let value):
            return value.label.isEmpty ? sharedProviderLabel(value.kind) : value.label
        case .native(let value):
            return value.label.isEmpty ? nativeProviderLabel(value.provider) : value.label
        }
    }

    static func countLabel(_ count: Int) -> String {
        String(format: String(localized: "coderouter.sidebar.accountCount", defaultValue: "%d"), count)
    }

    static func periodLabel(_ days: Int) -> String {
        String(format: String(localized: "coderouter.sidebar.usage.period", defaultValue: "Last %d days"), days)
    }

    static func createdLabel(_ date: Date) -> String {
        String(
            format: String(localized: "coderouter.sidebar.created", defaultValue: "Added %@"),
            date.formatted(date: .abbreviated, time: .omitted)
        )
    }

    static func claudeProviderLabel(_ kind: String) -> String {
        switch kind {
        case "anthropic_api_key":
            return String(localized: "coderouter.sidebar.provider.anthropicKey", defaultValue: "Anthropic API key")
        case "anthropic_oauth":
            return String(localized: "coderouter.sidebar.provider.claudeOAuth", defaultValue: "Claude Code OAuth")
        case "bedrock":
            return String(localized: "coderouter.sidebar.provider.bedrock", defaultValue: "Amazon Bedrock")
        default:
            return kind
        }
    }

    static func sharedProviderLabel(_ kind: String) -> String {
        switch kind {
        case "claude":
            return String(localized: "coderouter.sidebar.provider.claude", defaultValue: "Claude")
        case "codex":
            return String(localized: "coderouter.sidebar.provider.codex", defaultValue: "Codex")
        case "anthropic-apikey", "anthropic-key":
            return String(localized: "coderouter.sidebar.provider.anthropicKey", defaultValue: "Anthropic API key")
        case "openai-apikey", "openai-key":
            return String(localized: "coderouter.sidebar.provider.openAIKey", defaultValue: "OpenAI API key")
        default:
            return kind
        }
    }

    static func nativeProviderLabel(_ provider: String) -> String {
        switch provider {
        case "codex":
            return String(localized: "coderouter.sidebar.provider.codex", defaultValue: "Codex")
        case "openai-apikey":
            return String(localized: "coderouter.sidebar.provider.openAIKey", defaultValue: "OpenAI API key")
        case "openrouter-apikey":
            return String(localized: "coderouter.sidebar.provider.openRouterKey", defaultValue: "OpenRouter API key")
        default:
            return provider
        }
    }

    static func sessionLabel(_ count: Int) -> String {
        String(format: String(localized: "coderouter.sidebar.sessions", defaultValue: "%d sessions"), count)
    }

    static func compactNumber(_ value: Int) -> String {
        let absolute = abs(value)
        if absolute >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if absolute >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return String(value)
    }

    static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }

    static func userMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
