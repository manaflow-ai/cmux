internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation
internal import OSLog

nonisolated private let notificationSettingsLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    private static var notificationSettingsCapability: String { "notification.settings.v1" }
    private static var notificationSettingsCapabilityTimeoutNanoseconds: UInt64 { 750_000_000 }

    /// Whether the Mac supports phone notification settings sync.
    public var supportsNotificationSettings: Bool {
        supportedHostCapabilities.contains(Self.notificationSettingsCapability)
    }

    /// Sync the phone notification preferences to the connected Mac.
    ///
    /// Returns the Mac's echoed preferences when the current Mac accepted the
    /// update, or `nil` when there is no active Mac connection or the request
    /// failed. The caller keeps the local settings in either case so a later
    /// connection can retry.
    public func syncNotificationPreferencesToMac(
        _ preferences: MobileNotificationPreferences
    ) async -> MobileNotificationPreferences? {
        guard let client = remoteClient else { return nil }
        guard await ensureNotificationSettingsCapability(client: client) else { return nil }
        guard remoteClient === client else { return nil }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "notification.settings.set",
                params: [
                    "enabled": preferences.isForwardingEnabled,
                    "mode": preferences.forwardingMode.rawValue,
                    "hide_content": preferences.hidesContent,
                    "client_id": clientID,
                ]
            )
            let data = try await client.sendRequest(request)
            guard remoteClient === client else { return nil }
            let response = try JSONDecoder().decode(MobileNotificationSettingsResponse.self, from: data)
            return MobileNotificationPreferences(
                isEnabled: preferences.isEnabled,
                isForwardingEnabled: response.isEnabled,
                forwardingMode: response.forwardingMode,
                hidesContent: response.hidesContent
            )
        } catch {
            guard remoteClient === client else { return nil }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return nil }
            markMacConnectionUnavailableIfNeeded(after: error)
            notificationSettingsLog.error("notification settings sync failed: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// Read the connected Mac's phone notification settings.
    public func fetchNotificationPreferencesFromMac() async -> MobileNotificationPreferences? {
        guard let client = remoteClient else { return nil }
        guard await ensureNotificationSettingsCapability(client: client) else { return nil }
        guard remoteClient === client else { return nil }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "notification.settings.get",
                params: ["client_id": clientID]
            )
            let data = try await client.sendRequest(request)
            guard remoteClient === client else { return nil }
            let response = try JSONDecoder().decode(MobileNotificationSettingsResponse.self, from: data)
            return MobileNotificationPreferences(
                isEnabled: false,
                isForwardingEnabled: response.isEnabled,
                forwardingMode: response.forwardingMode,
                hidesContent: response.hidesContent
            )
        } catch {
            guard remoteClient === client else { return nil }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return nil }
            markMacConnectionUnavailableIfNeeded(after: error)
            notificationSettingsLog.error("notification settings fetch failed: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    private func ensureNotificationSettingsCapability(client: MobileCoreRPCClient) async -> Bool {
        if supportedHostCapabilities.isEmpty {
            await refreshNotificationSettingsCapabilities(client: client)
        }
        return supportsNotificationSettings
    }

    private func refreshNotificationSettingsCapabilities(client: MobileCoreRPCClient) async {
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "mobile.host.status", params: [:]),
                timeoutNanoseconds: Self.notificationSettingsCapabilityTimeoutNanoseconds
            )
            guard remoteClient === client,
                  let response = try? MobileHostStatusResponse.decode(data) else { return }
            supportedHostCapabilities = Set(response.capabilities)
        } catch {
            guard remoteClient === client else { return }
            notificationSettingsLog.error("notification settings capability probe failed: \(String(describing: error), privacy: .private)")
        }
    }
}
