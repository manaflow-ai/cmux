import CmuxFoundation
import SwiftUI

@MainActor
public struct IntegrationsSection: View {
    private let hostActions: SettingsHostActions

    @State private var snapshot: IntegrationSettingsSnapshot
    @State private var connectSheetSource: IntegrationSettingsSource?
    @State private var isSyncingAll = false

    public init(hostActions: SettingsHostActions) {
        self.hostActions = hostActions
        _snapshot = State(initialValue: hostActions.integrationSettingsSnapshot())
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.integrations", defaultValue: "Integrations"), section: .integrations)
            SettingsCard {
                privacyNote
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .action,
                    searchAnchorID: "setting:integrations:syncAll",
                    String(localized: "settings.integrations.syncAll", defaultValue: "Sync All"),
                    subtitle: String(localized: "settings.integrations.syncAll.subtitle", defaultValue: "Refresh every configured connector without launching source apps.")
                ) {
                    Button(String(localized: "settings.integrations.sync", defaultValue: "Sync")) {
                        sync(source: nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSyncingAll)
                }

                ForEach(IntegrationSettingsSource.allCases) { source in
                    SettingsCardDivider()
                    sourceBlock(source)
                }
            }
            .settingsSearchAnchors(["setting:integrations:integrations"])
        }
        .sheet(item: $connectSheetSource) { source in
            IntegrationConnectSheet(
                source: source,
                hostActions: hostActions,
                sourceTitle: sourceTitle(source),
                onUpdated: { snapshot = hostActions.integrationSettingsSnapshot() }
            )
        }
        .task { await observeUpdates() }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(String(localized: "settings.integrations.privacy.title", defaultValue: "Local-first inbox"), systemImage: "lock.shield")
                .cmuxFont(size: 12, weight: .semibold)
            Text(String(localized: "settings.integrations.privacy.body", defaultValue: "Normalized inbox data is stored locally in ~/.cmuxterm/inbox.sqlite3. Credentials live only in the local credential vault (Keychain when available). AI drafting runs only when you request a draft, and external replies are never sent until you approve Send."))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSearchAnchors(["setting:integrations:integration-privacy"])
    }

    private func sourceBlock(_ source: IntegrationSettingsSource) -> some View {
        VStack(spacing: 0) {
            SettingsCardRow(
                configurationReview: .action,
                searchAnchorID: "setting:integrations:\(source.rawValue)",
                sourceTitle(source),
                subtitle: sourceSubtitle(source)
            ) {
                HStack(spacing: 8) {
                    if snapshot.unreadCount(for: source) > 0 {
                        Text("\(snapshot.unreadCount(for: source))")
                            .cmuxFont(size: 11, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Button(String(localized: "settings.integrations.sync", defaultValue: "Sync")) {
                        sync(source: source)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            let accounts = snapshot.accounts(for: source)
            if accounts.isEmpty {
                if source != .agent {
                    connectRow(source)
                }
            } else {
                ForEach(accounts) { account in
                    SettingsCardDivider()
                    IntegrationAccountRow(
                        account: account,
                        statusText: account.statusMessage ?? account.status,
                        onNotificationsChanged: { enabled in
                            Task {
                                await hostActions.setIntegrationNotificationsEnabled(
                                    source: account.source,
                                    accountID: account.accountID,
                                    enabled: enabled
                                )
                            }
                        },
                        onDisconnect: {
                            Task {
                                await hostActions.disconnectIntegration(source: account.source, accountID: account.accountID)
                                snapshot = hostActions.integrationSettingsSnapshot()
                            }
                        }
                    )
                }
            }
        }
    }

    private func connectRow(_ source: IntegrationSettingsSource) -> some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:integrations:\(source.rawValue):connect",
            connectTitle(source),
            subtitle: connectSubtitle(source)
        ) {
            Button {
                connectSheetSource = source
            } label: {
                Text(String(localized: "settings.integrations.connectEllipsis", defaultValue: "Connect…"))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("IntegrationsSection.connect.\(source.rawValue)")
        }
    }

    private func sync(source: IntegrationSettingsSource?) {
        isSyncingAll = source == nil
        Task {
            await hostActions.syncIntegration(source: source)
            snapshot = hostActions.integrationSettingsSnapshot()
            isSyncingAll = false
        }
    }

    /// Follows host integration updates for the lifetime of the enclosing
    /// SwiftUI `.task` so the subscription ends when the section disappears.
    /// Spawning an inner unstructured task here leaked one live host stream
    /// (and its refresh work) per appearance until process exit.
    private func observeUpdates() async {
        snapshot = hostActions.integrationSettingsSnapshot()
        for await next in hostActions.integrationSettingsUpdates() {
            snapshot = next
        }
    }

    private func sourceTitle(_ source: IntegrationSettingsSource) -> String {
        switch source {
        case .agent: return String(localized: "settings.integrations.source.agents", defaultValue: "Agents")
        case .gmail: return String(localized: "settings.integrations.source.gmail", defaultValue: "Gmail")
        case .slack: return String(localized: "settings.integrations.source.slack", defaultValue: "Slack")
        case .discord: return String(localized: "settings.integrations.source.discord", defaultValue: "Discord")
        case .imessage: return String(localized: "settings.integrations.source.imessage", defaultValue: "iMessage")
        case .generic: return String(localized: "settings.integrations.source.generic", defaultValue: "Generic")
        }
    }

    private func sourceSubtitle(_ source: IntegrationSettingsSource) -> String {
        switch source {
        case .agent:
            return String(localized: "settings.integrations.source.agents.subtitle", defaultValue: "Mirrors existing Feed and Workstream events into Inbox.")
        case .gmail:
            return String(localized: "settings.integrations.source.gmail.subtitle", defaultValue: "OAuth-ready Gmail API history polling, labels, threads, unread, and approved reply sends.")
        case .slack:
            return String(localized: "settings.integrations.source.slack.subtitle", defaultValue: "Slack Web API backfill plus Socket Mode event shape for near-real-time activity.")
        case .discord:
            return String(localized: "settings.integrations.source.discord.subtitle", defaultValue: "Official bot and Gateway connector for selected channels, mentions, DMs, and accessible threads.")
        case .imessage:
            return String(localized: "settings.integrations.source.imessage.subtitle", defaultValue: "Uses the cmux-imsg helper for status, recent sync, history, dedupe, and approved sends.")
        case .generic:
            return String(localized: "settings.integrations.source.generic.subtitle", defaultValue: "Accepts normalized events from CLI, Shortcuts, webhooks, Zapier, or internal tools.")
        }
    }

    private func connectTitle(_ source: IntegrationSettingsSource) -> String {
        String.localizedStringWithFormat(
            String(localized: "settings.integrations.connectSource", defaultValue: "Connect %@"),
            sourceTitle(source)
        )
    }

    private func connectSubtitle(_ source: IntegrationSettingsSource) -> String {
        source.requiresTokenField
            ? String(localized: "settings.integrations.connect.token.subtitle", defaultValue: "Opens a guided setup that stores the token in the local credential vault and verifies the connection.")
            : String(localized: "settings.integrations.connect.noToken.subtitle", defaultValue: "Records this source locally and reports helper or credential status.")
    }
}

private extension IntegrationSettingsSource {
    var requiresTokenField: Bool {
        self == .gmail || self == .slack || self == .discord
    }
}
