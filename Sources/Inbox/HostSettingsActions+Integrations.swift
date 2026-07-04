import CmuxInbox
import CmuxSettingsUI
import Foundation
import OSLog

@MainActor
extension HostSettingsActions {
    func integrationSettingsSnapshot() -> IntegrationSettingsSnapshot {
        guard let inboxRuntime else { return IntegrationSettingsSnapshot() }
        return Self.integrationSnapshot(
            accounts: inboxRuntime.accounts,
            statuses: inboxRuntime.statuses,
            unreadCounts: inboxRuntime.unreadCounts
        )
    }

    func integrationSettingsUpdates() -> AsyncStream<IntegrationSettingsSnapshot> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self, let inboxRuntime = self.inboxRuntime else {
                    continuation.finish()
                    return
                }
                continuation.yield(self.integrationSettingsSnapshot())
                for await _ in await inboxRuntime.hub.changes() {
                    // seedNotifications must stay false here: seeding marks new
                    // unread items as already seen, so a live Settings stream
                    // would silently suppress inbox notification previews for
                    // every change that arrives while the pane is open.
                    await inboxRuntime.refresh(seedNotifications: false)
                    continuation.yield(self.integrationSettingsSnapshot())
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func connectIntegration(
        source: IntegrationSettingsSource,
        accountID: String,
        displayName: String?,
        token: String?
    ) async -> IntegrationAccountSettingsSnapshot? {
        guard let inboxRuntime, let inboxSource = InboxSource(settingsSource: source) else { return nil }
        do {
            try await inboxRuntime.connect(
                source: inboxSource,
                accountID: accountID,
                displayName: displayName,
                token: token
            )
            return integrationSettingsSnapshot().accounts(for: source).first { $0.accountID == accountID }
        } catch {
            hostSettingsLogger.error("failed to connect integration source=\(source.rawValue, privacy: .public)")
            return nil
        }
    }

    func disconnectIntegration(source: IntegrationSettingsSource, accountID: String) async {
        guard let inboxRuntime, let inboxSource = InboxSource(settingsSource: source) else { return }
        do {
            try await inboxRuntime.disconnect(source: inboxSource, accountID: accountID)
        } catch {
            hostSettingsLogger.error("failed to disconnect integration source=\(source.rawValue, privacy: .public)")
        }
    }

    func signInIntegration(source: IntegrationSettingsSource) async -> IntegrationSignInResult {
        guard source == .gmail else { return .unsupported }
        guard let inboxRuntime else { return .unavailable(Self.gmailUnavailableMessage) }
        guard let configuration = GmailOAuthCoordinator.ClientConfiguration.fromCmuxConfig() else {
            return .unavailable(Self.gmailUnavailableMessage)
        }
        do {
            let credentialJSON = try await GmailOAuthCoordinator().signIn(configuration: configuration)
            try await inboxRuntime.connect(source: .gmail, accountID: "default", displayName: "Gmail", token: credentialJSON)
            inboxRuntime.sync(source: .gmail)
            if let account = integrationSettingsSnapshot().accounts(for: .gmail).first {
                return .connected(account)
            }
            return .cancelled
        } catch GmailOAuthCoordinator.OAuthError.cancelled {
            return .cancelled
        } catch {
            hostSettingsLogger.error("gmail sign-in failed")
            return .failed(String(localized: "settings.integrations.gmail.signInFailed", defaultValue: "Google sign-in did not complete. Please try again."))
        }
    }

    private static var gmailUnavailableMessage: String {
        String(localized: "settings.integrations.gmail.needsClient", defaultValue: "Add a Google OAuth client id under integrations.gmail.client_id in ~/.config/cmux/cmux.json to enable one-click Gmail sign-in. You can also paste an access token below.")
    }

    func syncIntegration(source: IntegrationSettingsSource?) async {
        let inboxSource = source.flatMap(InboxSource.init(settingsSource:))
        inboxRuntime?.sync(source: inboxSource)
    }

    func setIntegrationNotificationsEnabled(
        source: IntegrationSettingsSource,
        accountID: String,
        enabled: Bool
    ) async {
        guard let inboxRuntime, let inboxSource = InboxSource(settingsSource: source) else { return }
        do {
            try await inboxRuntime.setNotificationsEnabled(
                source: inboxSource,
                accountID: accountID,
                enabled: enabled
            )
        } catch {
            hostSettingsLogger.error("failed to update integration notifications source=\(source.rawValue, privacy: .public)")
        }
    }

    private static func integrationSnapshot(
        accounts: [InboxAccount],
        statuses: [InboxConnectorStatus],
        unreadCounts: [InboxSourceUnreadCount]
    ) -> IntegrationSettingsSnapshot {
        let statusByID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
        let accountSnapshots = accounts.map { account in
            let status = statusByID["\(account.source.rawValue):\(account.accountID)"]
            return IntegrationAccountSettingsSnapshot(
                source: IntegrationSettingsSource(inboxSource: account.source) ?? .generic,
                accountID: account.accountID,
                displayName: account.displayName,
                status: InboxLocalized.statusLabel(status?.status ?? account.status),
                statusMessage: status?.message ?? account.statusMessage,
                credentialState: (status?.credentialState ?? .missing).rawValue,
                capabilities: account.capabilities.sorted { $0.rawValue < $1.rawValue }.map(InboxLocalized.capabilityLabel),
                lastSyncDescription: Self.lastSyncDescription(status?.lastSyncAt ?? account.lastSyncAt),
                notificationsEnabled: account.notificationsEnabled
            )
        }
        let counts = Dictionary(uniqueKeysWithValues: unreadCounts.compactMap { count in
            IntegrationSettingsSource(inboxSource: count.source).map { ($0, count.unreadCount) }
        })
        return IntegrationSettingsSnapshot(accounts: accountSnapshots, unreadCounts: counts)
    }

    private static func lastSyncDescription(_ date: Date?) -> String? {
        guard let date else { return nil }
        return String.localizedStringWithFormat(
            String(localized: "settings.integrations.lastSync", defaultValue: "Last sync %@"),
            DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
        )
    }
}

private extension InboxSource {
    init?(settingsSource: IntegrationSettingsSource) {
        self.init(rawValue: settingsSource.rawValue)
    }
}

private extension IntegrationSettingsSource {
    init?(inboxSource: InboxSource) {
        self.init(rawValue: inboxSource.rawValue)
    }
}
