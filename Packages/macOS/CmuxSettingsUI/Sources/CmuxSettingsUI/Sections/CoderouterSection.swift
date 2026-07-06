import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **AI Gateway** section for cmux coderouter routing.
@MainActor
public struct CoderouterSection: View {
    private let coderouterFlow: CoderouterFlow?

    @State private var routeClaudeModel: DefaultsValueModel<Bool>
    @State private var gatewayKeyModel: SecretValueModel
    @State private var isCreatingKey = false
    @State private var revealedKey: String?
    @State private var createKeyErrorMessage: String?

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        secretStore: SecretFileStore,
        catalog: SettingCatalog,
        coderouterFlow: CoderouterFlow?
    ) {
        self.coderouterFlow = coderouterFlow
        _routeClaudeModel = State(initialValue: DefaultsValueModel(
            store: defaultsStore,
            key: catalog.integrations.routeClaudeThroughCoderouter
        ))
        _gatewayKeyModel = State(initialValue: SecretValueModel(
            store: secretStore,
            key: catalog.automation.coderouterGatewayKey,
            errorLog: SettingsErrorLog(capacity: 4)
        ))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.coderouter", defaultValue: "AI Gateway"), section: .coderouter)
            SettingsCard {
                statusRow
                SettingsCardDivider()
                gatewayBaseURLRow
                SettingsCardDivider()
                routeClaudeRow
                SettingsCardDivider()
                createKeyRow
                if let revealedKey {
                    SettingsCardDivider()
                    revealedKeyRow(revealedKey)
                }
                if let createKeyErrorMessage {
                    SettingsCardDivider()
                    errorRow(createKeyErrorMessage)
                }
                SettingsCardDivider()
                SettingsCardNote(
                    String(localized: "settings.coderouter.note", defaultValue: "Routing currently covers Claude Code.")
                )
            }
            .settingsSearchAnchors(["setting:coderouter:gateway"])
        }
        .task { startObservingSettings() }
    }

    private var gatewayBaseURL: String {
        coderouterFlow?.gatewayBaseURL ?? String(localized: "settings.coderouter.gatewayBaseURL.unavailable", defaultValue: "Unavailable")
    }

    private var hasStoredKey: Bool {
        !gatewayKeyModel.current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSignedIn: Bool {
        coderouterFlow?.isSignedIn == true
    }

    private func startObservingSettings() {
        routeClaudeModel.startObserving()
        gatewayKeyModel.startObserving()
    }

    @ViewBuilder
    private var statusRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            String(localized: "settings.coderouter.status", defaultValue: "Status"),
            subtitle: statusSubtitle
        ) {
            Image(systemName: isSignedIn ? "checkmark.circle" : "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(isSignedIn ? Color.green : Color.secondary)
        }
    }

    private var statusSubtitle: String {
        if !isSignedIn {
            return String(localized: "settings.coderouter.status.signedOut", defaultValue: "Sign in to cmux to create a gateway key.")
        }
        if hasStoredKey {
            return String(localized: "settings.coderouter.status.keyStored", defaultValue: "A gateway key is stored for this Mac.")
        }
        return String(localized: "settings.coderouter.status.ready", defaultValue: "Create a gateway key before enabling routed Claude Code launches.")
    }

    @ViewBuilder
    private var gatewayBaseURLRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            String(localized: "settings.coderouter.gatewayBaseURL", defaultValue: "Gateway Base URL")
        ) {
            Text(gatewayBaseURL)
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var routeClaudeRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:coderouter:route-claude",
            String(localized: "settings.coderouter.routeClaude", defaultValue: "Route Claude Code through the cmux gateway"),
            subtitle: routeClaudeSubtitle
        ) {
            Toggle("", isOn: Binding(get: { routeClaudeModel.current }, set: { routeClaudeModel.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsCoderouterRouteClaudeToggle")
        }
    }

    private var routeClaudeSubtitle: String {
        if routeClaudeModel.current && !hasStoredKey {
            return String(localized: "settings.coderouter.routeClaude.subtitleNeedsKey", defaultValue: "Routing stays inactive until a gateway key is stored.")
        }
        return String(localized: "settings.coderouter.routeClaude.subtitle", defaultValue: "When enabled, new Claude Code launches use coderouter for Anthropic API traffic.")
    }

    @ViewBuilder
    private var createKeyRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:coderouter:create-key",
            String(localized: "settings.coderouter.createKey", defaultValue: "Create Gateway Key"),
            subtitle: String(localized: "settings.coderouter.createKey.subtitle", defaultValue: "Creates a team-scoped key and stores it in this Mac's cmux secret store.")
        ) {
            Button {
                createGatewayKey()
            } label: {
                if isCreatingKey {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(String(localized: "settings.coderouter.createKey.button", defaultValue: "Create"))
                }
            }
            .disabled(!isSignedIn || isCreatingKey)
            .accessibilityIdentifier("SettingsCoderouterCreateKeyButton")
        }
    }

    @ViewBuilder
    private func revealedKeyRow(_ key: String) -> some View {
        SettingsCardRow(
            configurationReview: .action,
            String(localized: "settings.coderouter.revealedKey", defaultValue: "New Gateway Key"),
            subtitle: String(localized: "settings.coderouter.revealedKey.subtitle", defaultValue: "Shown once. It has already been stored for future launches.")
        ) {
            Text(key)
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func errorRow(_ message: String) -> some View {
        SettingsCardRow(
            configurationReview: .action,
            String(localized: "settings.coderouter.createKey.error", defaultValue: "Key Creation Failed"),
            subtitle: message
        ) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func createGatewayKey() {
        guard let coderouterFlow, coderouterFlow.isSignedIn, !isCreatingKey else { return }
        isCreatingKey = true
        createKeyErrorMessage = nil
        Task { @MainActor in
            do {
                let key = try await coderouterFlow.createKey()
                gatewayKeyModel.set(key)
                revealedKey = key
            } catch {
                createKeyErrorMessage = error.localizedDescription
            }
            isCreatingKey = false
        }
    }
}
