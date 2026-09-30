import CmuxCloud
import SwiftUI

/// Collects one explicit CodeRouter account addition for the active team.
struct CoderouterAddAccountSheet: View {
    private enum Kind: String, CaseIterable, Identifiable {
        case claudeOAuth
        case anthropicAPIKey
        case bedrock
        case localClaude
        case localCodex
        case localAnthropicKey
        case localOpenAIKey
        case nativeOpenAIKey
        case nativeOpenRouterKey

        var id: String { rawValue }
    }

    let model: CoderouterAccountsPanelModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .claudeOAuth
    @State private var label = ""
    @State private var secret = ""
    @State private var region = "us-west-2"
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var sessionToken = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "coderouter.sidebar.add.title", defaultValue: "Add CodeRouter account"))
                        .font(.title3.weight(.semibold))
                    Text(String(localized: "coderouter.sidebar.add.subtitle", defaultValue: "Credentials are sent only after you press Add and are never displayed again."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "coderouter.sidebar.cancel", defaultValue: "Cancel"))
            }

            Picker(String(localized: "coderouter.sidebar.add.provider", defaultValue: "Provider"), selection: $kind) {
                Section(String(localized: "coderouter.sidebar.add.claudeSection", defaultValue: "Claude upstream")) {
                    Text(String(localized: "coderouter.sidebar.provider.claudeOAuth", defaultValue: "Claude Code OAuth")).tag(Kind.claudeOAuth)
                    Text(String(localized: "coderouter.sidebar.provider.anthropicKey", defaultValue: "Anthropic API key")).tag(Kind.anthropicAPIKey)
                    Text(String(localized: "coderouter.sidebar.provider.bedrock", defaultValue: "Amazon Bedrock")).tag(Kind.bedrock)
                }
                Section(String(localized: "coderouter.sidebar.add.localSection", defaultValue: "Local account upload")) {
                    Text(String(localized: "coderouter.sidebar.provider.claude", defaultValue: "Claude")).tag(Kind.localClaude)
                    Text(String(localized: "coderouter.sidebar.provider.codex", defaultValue: "Codex")).tag(Kind.localCodex)
                    Text(String(localized: "coderouter.sidebar.provider.anthropicKey", defaultValue: "Anthropic API key")).tag(Kind.localAnthropicKey)
                    Text(String(localized: "coderouter.sidebar.provider.openAIKey", defaultValue: "OpenAI API key")).tag(Kind.localOpenAIKey)
                }
                Section(String(localized: "coderouter.sidebar.add.nativeSection", defaultValue: "CodeRouter account pool")) {
                    Text(String(localized: "coderouter.sidebar.provider.openAIKey", defaultValue: "OpenAI API key")).tag(Kind.nativeOpenAIKey)
                    Text(String(localized: "coderouter.sidebar.provider.openRouterKey", defaultValue: "OpenRouter API key")).tag(Kind.nativeOpenRouterKey)
                }
            }
            .pickerStyle(.menu)

            formFields

            if !ManagedAICredentialUploadPolicy.isEnabled {
                Label(ManagedAICredentialUploadPolicy.disabledMessage, systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("CoderouterAddError")
            }

            HStack {
                Spacer()
                Button(String(localized: "coderouter.sidebar.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(String(localized: "coderouter.sidebar.add.action", defaultValue: "Add account"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || !ManagedAICredentialUploadPolicy.isEnabled)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onDisappear { saveTask?.cancel() }
    }

    @ViewBuilder
    private var formFields: some View {
        switch kind {
        case .claudeOAuth:
            SecureField(
                String(localized: "coderouter.sidebar.add.oauthToken", defaultValue: "Claude setup token"),
                text: $secret
            )
            Text(String(localized: "coderouter.sidebar.add.oauthHint", defaultValue: "Create one with `claude setup-token`, then paste it here."))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .anthropicAPIKey:
            SecureField(
                String(localized: "coderouter.sidebar.provider.anthropicKey", defaultValue: "Anthropic API key"),
                text: $secret
            )
        case .bedrock:
            TextField(String(localized: "coderouter.sidebar.add.region", defaultValue: "AWS region"), text: $region)
            TextField(String(localized: "coderouter.sidebar.add.accessKey", defaultValue: "AWS access key ID"), text: $accessKeyID)
            SecureField(String(localized: "coderouter.sidebar.add.secretKey", defaultValue: "AWS secret access key"), text: $secretAccessKey)
            SecureField(String(localized: "coderouter.sidebar.add.sessionToken", defaultValue: "AWS session token (optional)"), text: $sessionToken)
        case .localClaude, .localCodex:
            if kind == .localClaude {
                Text(String(localized: "coderouter.sidebar.add.localClaudeHint", defaultValue: "cmux will read your local Claude login after you press Add."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(String(localized: "coderouter.sidebar.add.localCodexHint", defaultValue: "cmux will read your local Codex login after you press Add."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .localAnthropicKey, .localOpenAIKey:
            SecureField(
                String(localized: "coderouter.sidebar.add.apiKeyOptional", defaultValue: "API key (optional if set in the environment)"),
                text: $secret
            )
            Text(String(localized: "coderouter.sidebar.add.apiKeyHint", defaultValue: "If left blank, cmux uses the provider's environment variable."))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .nativeOpenAIKey, .nativeOpenRouterKey:
            SecureField(
                String(localized: "coderouter.sidebar.add.nativeApiKey", defaultValue: "API key"),
                text: $secret
            )
            Text(String(localized: "coderouter.sidebar.add.nativeKeyHint", defaultValue: "This key is stored in the team's CodeRouter account pool."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        TextField(String(localized: "coderouter.sidebar.add.label", defaultValue: "Label (optional)"), text: $label)
    }

    private func save() {
        guard !isSaving else { return }
        errorMessage = nil
        isSaving = true
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            defer {
                isSaving = false
                saveTask = nil
            }
            do {
                switch kind {
                case .claudeOAuth:
                    let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { throw InputError.missingCredential }
                    try await model.addClaude(.anthropicOAuth(token: value), label: normalizedLabel)
                case .anthropicAPIKey:
                    let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { throw InputError.missingCredential }
                    try await model.addClaude(.anthropicAPIKey(value), label: normalizedLabel)
                case .bedrock:
                    let values = [region, accessKeyID, secretAccessKey].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    guard values.allSatisfy({ !$0.isEmpty }) else { throw InputError.missingCredential }
                    try await model.addClaude(
                        .bedrock(
                            region: values[0],
                            accessKeyID: values[1],
                            secretAccessKey: values[2],
                            sessionToken: normalized(sessionToken),
                            modelIDs: [:]
                        ),
                        label: normalizedLabel
                    )
                case .localClaude:
                    let payload = try AIAccountCredentialSources().uploadPayload(
                        provider: .claude,
                        label: normalizedLabel,
                        explicitAPIKey: nil
                    )
                    try await model.addShared(payload)
                case .localCodex:
                    let payload = try AIAccountCredentialSources().uploadPayload(
                        provider: .codex,
                        label: normalizedLabel,
                        explicitAPIKey: nil
                    )
                    try await model.addShared(payload)
                case .localAnthropicKey:
                    let payload = try AIAccountCredentialSources().uploadPayload(
                        provider: .anthropicKey,
                        label: normalizedLabel,
                        explicitAPIKey: normalized(secret)
                    )
                    try await model.addShared(payload)
                case .localOpenAIKey:
                    let payload = try AIAccountCredentialSources().uploadPayload(
                        provider: .openAIKey,
                        label: normalizedLabel,
                        explicitAPIKey: normalized(secret)
                    )
                    try await model.addShared(payload)
                case .nativeOpenAIKey, .nativeOpenRouterKey:
                    guard let key = normalized(secret) else { throw InputError.missingCredential }
                    let provider: CoderouterAPIKeyProvider = kind == .nativeOpenAIKey ? .openAI : .openRouter
                    try await model.addNativeAPIKey(provider: provider, apiKey: key, label: normalizedLabel)
                }
                dismiss()
            } catch {
                errorMessage = Self.userMessage(error)
            }
        }
    }

    private var normalizedLabel: String? { normalized(label) }

    private func normalized(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func userMessage(_ error: Error) -> String {
        if let input = error as? InputError {
            return input.errorDescription ?? String(localized: "coderouter.sidebar.add.missingCredential", defaultValue: "Enter the required credential, then try again.")
        }
        if error is CoderouterAccountsPanelModel.ServiceUnavailable {
            return String(localized: "coderouter.sidebar.serviceUnavailable", defaultValue: "CodeRouter is temporarily unavailable.")
        }
        if error is AIAccountCredentialSourceError {
            return String(localized: "coderouter.sidebar.add.localCredentialMissing", defaultValue: "Sign in to the provider locally, then try again.")
        }
        return String(localized: "coderouter.sidebar.serviceUnavailable", defaultValue: "CodeRouter is temporarily unavailable.")
    }

    private enum InputError: Error, LocalizedError {
        case missingCredential

        var errorDescription: String? {
            String(localized: "coderouter.sidebar.add.missingCredential", defaultValue: "Enter the required credential, then try again.")
        }
    }
}
