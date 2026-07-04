import CmuxFoundation
import SwiftUI

/// Guided per-source linking flow for Settings > Integrations.
///
/// Replaces raw account/token fields with source-specific steps, a link to the
/// exact external page that issues the credential, one token field, and live
/// validation: Connect stores the token through the host, then a sync runs so
/// the sheet shows the real resulting status instead of optimistic success.
@MainActor
struct IntegrationConnectSheet: View {
    let source: IntegrationSettingsSource
    let hostActions: SettingsHostActions
    let sourceTitle: String
    let onUpdated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var phase: Phase = .editing
    @State private var showTokenField = false

    private enum Phase: Equatable {
        case editing
        case connecting
        case verifying
        case finished(status: String, message: String?, healthy: Bool)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            steps
            if source.supportsNativeSignIn {
                nativeSignInButton
                tokenDisclosure
            } else if needsToken {
                SecureField(
                    String(localized: "settings.integrations.token.placeholder", defaultValue: "Token"),
                    text: $token
                )
                .textFieldStyle(.roundedBorder)
                .disabled(phase == .connecting || phase == .verifying)
            }
            resultView
            footer
        }
        .padding(18)
        .frame(width: 460)
        .accessibilityIdentifier("IntegrationConnectSheet.\(source.rawValue)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String.localizedStringWithFormat(
                String(localized: "settings.integrations.connectSource", defaultValue: "Connect %@"),
                sourceTitle
            ))
            .cmuxFont(size: 15, weight: .semibold)
            Text(String(localized: "settings.integrations.connectSheet.subtitle", defaultValue: "Tokens are stored in the local credential vault and never written to settings, the inbox database, or logs."))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(guidedSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .cmuxFont(size: 10, weight: .bold)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.accentColor.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.text)
                            .cmuxFont(size: 11.5)
                            .fixedSize(horizontal: false, vertical: true)
                        if let link = step.link {
                            Link(destination: link.url) {
                                Label(link.label, systemImage: "arrow.up.right.square")
                                    .cmuxFont(size: 11, weight: .medium)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.06)))
    }

    private var nativeSignInButton: some View {
        Button {
            signInWithProvider()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "person.badge.key.fill")
                Text(String(localized: "settings.integrations.gmail.signInButton", defaultValue: "Sign in with Google"))
                    .cmuxFont(size: 12, weight: .semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(phase == .connecting || phase == .verifying)
        .accessibilityIdentifier("IntegrationConnectSheet.signIn")
    }

    @ViewBuilder
    private var tokenDisclosure: some View {
        if showTokenField {
            SecureField(
                String(localized: "settings.integrations.token.placeholder", defaultValue: "Token"),
                text: $token
            )
            .textFieldStyle(.roundedBorder)
            .disabled(phase == .connecting || phase == .verifying)
        } else {
            Button {
                showTokenField = true
            } label: {
                Text(String(localized: "settings.integrations.gmail.pasteTokenInstead", defaultValue: "Paste an access token instead"))
                    .cmuxFont(size: 11)
            }
            .buttonStyle(.link)
        }
    }

    private func signInWithProvider() {
        phase = .connecting
        Task {
            let result = await hostActions.signInIntegration(source: source)
            onUpdated()
            switch result {
            case .connected(let account):
                phase = .finished(status: account.status, message: account.statusMessage, healthy: true)
            case .cancelled:
                phase = .editing
            case .unsupported:
                showTokenField = true
                phase = .editing
            case .unavailable(let message):
                showTokenField = true
                phase = .finished(status: String(localized: "settings.integrations.connectSheet.needsSetup", defaultValue: "Setup needed"), message: message, healthy: false)
            case .failed(let message):
                phase = .finished(
                    status: String(localized: "settings.integrations.connectSheet.failed", defaultValue: "Connection failed"),
                    message: message,
                    healthy: false
                )
            }
        }
    }

    @ViewBuilder
    private var resultView: some View {
        switch phase {
        case .editing:
            EmptyView()
        case .connecting:
            Label(
                String(localized: "settings.integrations.connectSheet.connecting", defaultValue: "Connecting…"),
                systemImage: "circle.dotted"
            )
            .cmuxFont(.caption)
            .foregroundStyle(.secondary)
        case .verifying:
            Label(
                String(localized: "settings.integrations.connectSheet.verifying", defaultValue: "Checking the connection…"),
                systemImage: "arrow.triangle.2.circlepath"
            )
            .cmuxFont(.caption)
            .foregroundStyle(.secondary)
        case .finished(let status, let message, let healthy):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(healthy ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status)
                        .cmuxFont(size: 11.5, weight: .semibold)
                    if let message, !message.isEmpty {
                        Text(message)
                            .cmuxFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityIdentifier("IntegrationConnectSheet.result")
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "common.cancel", defaultValue: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if case .finished(_, _, let healthy) = phase, healthy {
                Button(String(localized: "common.close", defaultValue: "Close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else if showConnectButton {
                Button(String(localized: "settings.integrations.connect", defaultValue: "Connect")) { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(connectDisabled)
            }
        }
    }

    /// Native-sign-in sources hide the manual Connect button unless the user
    /// explicitly reveals the token field (paste-token fallback).
    private var showConnectButton: Bool {
        !source.supportsNativeSignIn || showTokenField
    }

    private var connectDisabled: Bool {
        if phase == .connecting || phase == .verifying { return true }
        let tokenRequired = needsToken || (source.supportsNativeSignIn && showTokenField)
        if tokenRequired, token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }

    private var needsToken: Bool {
        source == .gmail || source == .slack || source == .discord
    }

    private func connect() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .connecting
        Task {
            let connected = await hostActions.connectIntegration(
                source: source,
                accountID: "default",
                displayName: nil,
                token: trimmed.isEmpty ? nil : trimmed
            )
            token = ""
            onUpdated()
            guard connected != nil else {
                phase = .finished(
                    status: String(localized: "settings.integrations.connectSheet.failed", defaultValue: "Connection failed"),
                    message: nil,
                    healthy: false
                )
                return
            }
            phase = .verifying
            await hostActions.syncIntegration(source: source)
            onUpdated()
            let latest = hostActions.integrationSettingsSnapshot().accounts(for: source).first
            let status = latest?.status ?? String(localized: "settings.integrations.connectSheet.failed", defaultValue: "Connection failed")
            phase = .finished(
                status: status,
                message: latest?.statusMessage,
                healthy: Self.isHealthy(rawStatus: latest?.status)
            )
        }
    }

    /// Raw status values come from the host's localized status labels, so
    /// health is derived from the host-provided health hint when present.
    private static func isHealthy(rawStatus: String?) -> Bool {
        guard let rawStatus else { return false }
        return rawStatus == String(localized: "inbox.status.connected", defaultValue: "Connected")
            || rawStatus == String(localized: "inbox.status.syncing", defaultValue: "Syncing")
    }

    private struct GuidedStep {
        let text: String
        let link: (label: String, url: URL)?

        init(_ text: String, link: (label: String, url: URL)? = nil) {
            self.text = text
            self.link = link
        }
    }

    private var guidedSteps: [GuidedStep] {
        switch source {
        case .slack:
            return [
                GuidedStep(
                    String(localized: "settings.integrations.connectSheet.slack.step1", defaultValue: "Create a Slack app in your workspace."),
                    link: (
                        String(localized: "settings.integrations.connectSheet.slack.link", defaultValue: "Open api.slack.com/apps"),
                        URL(string: "https://api.slack.com/apps?new_app=1")!
                    )
                ),
                GuidedStep(String(localized: "settings.integrations.connectSheet.slack.step2", defaultValue: "Under OAuth & Permissions, add the bot scopes channels:history, channels:read, and chat:write, then install the app to your workspace.")),
                GuidedStep(String(localized: "settings.integrations.connectSheet.slack.step3", defaultValue: "Copy the Bot User OAuth Token (it starts with xoxb-) and paste it below.")),
            ]
        case .discord:
            return [
                GuidedStep(
                    String(localized: "settings.integrations.connectSheet.discord.step1", defaultValue: "Create an application with a Bot in the Discord Developer Portal."),
                    link: (
                        String(localized: "settings.integrations.connectSheet.discord.link", defaultValue: "Open the Developer Portal"),
                        URL(string: "https://discord.com/developers/applications")!
                    )
                ),
                GuidedStep(String(localized: "settings.integrations.connectSheet.discord.step2", defaultValue: "Enable the Message Content intent and invite the bot to your server.")),
                GuidedStep(String(localized: "settings.integrations.connectSheet.discord.step3", defaultValue: "Copy the bot token and paste it below.")),
            ]
        case .gmail:
            return [
                GuidedStep(String(localized: "settings.integrations.connectSheet.gmail.step1", defaultValue: "Gmail currently links with an OAuth access token. One-click Google sign-in is on the roadmap.")),
                GuidedStep(
                    String(localized: "settings.integrations.connectSheet.gmail.step2", defaultValue: "Developer path: authorize Gmail scopes in Google's OAuth Playground and copy the access token."),
                    link: (
                        String(localized: "settings.integrations.connectSheet.gmail.link", defaultValue: "Open the OAuth Playground"),
                        URL(string: "https://developers.google.com/oauthplayground/")!
                    )
                ),
                GuidedStep(String(localized: "settings.integrations.connectSheet.gmail.step3", defaultValue: "Paste the access token below. Access tokens expire after about an hour; the status shows Token expired when it lapses.")),
            ]
        case .imessage:
            return [
                GuidedStep(String(localized: "settings.integrations.connectSheet.imessage.step1", defaultValue: "iMessage uses the local cmux-imsg helper. No credentials leave this Mac.")),
                GuidedStep(String(localized: "settings.integrations.connectSheet.imessage.step2", defaultValue: "The helper is not bundled yet, so the status shows Helper missing. Connecting records the account so it activates automatically once the helper ships.")),
            ]
        case .generic:
            return [
                GuidedStep(String(localized: "settings.integrations.connectSheet.generic.step1", defaultValue: "Generic accepts normalized events from your own tools. No credentials are needed.")),
                GuidedStep(String(localized: "settings.integrations.connectSheet.generic.step2", defaultValue: "Push events from anywhere with: cmux inbox push --json '<event-json>'")),
            ]
        case .agent:
            return [
                GuidedStep(String(localized: "settings.integrations.connectSheet.agent.step1", defaultValue: "Agent activity connects automatically from your local cmux sessions.")),
            ]
        }
    }
}
