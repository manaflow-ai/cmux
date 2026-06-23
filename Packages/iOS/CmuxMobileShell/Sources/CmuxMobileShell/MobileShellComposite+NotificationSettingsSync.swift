internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation
internal import OSLog

private let notificationSettingsLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
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
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "notification.settings.set",
                params: [
                    "enabled": preferences.isEnabled,
                    "mode": preferences.forwardingMode.rawValue,
                    "hide_content": preferences.hidesContent,
                    "client_id": clientID,
                ]
            )
            let data = try await client.sendRequest(request)
            guard remoteClient === client else { return nil }
            let response = try MobileNotificationSettingsResponse.decode(data)
            return MobileNotificationPreferences(
                isEnabled: response.isEnabled,
                forwardingMode: response.forwardingMode,
                hidesContent: response.hidesContent
            )
        } catch {
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return nil }
            markMacConnectionUnavailableIfNeeded(after: error)
            notificationSettingsLog.error("notification settings sync failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Read the connected Mac's phone notification settings.
    public func fetchNotificationPreferencesFromMac() async -> MobileNotificationPreferences? {
        guard let client = remoteClient else { return nil }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "notification.settings.get",
                params: ["client_id": clientID]
            )
            let data = try await client.sendRequest(request)
            guard remoteClient === client else { return nil }
            let response = try MobileNotificationSettingsResponse.decode(data)
            return MobileNotificationPreferences(
                isEnabled: response.isEnabled,
                forwardingMode: response.forwardingMode,
                hidesContent: response.hidesContent
            )
        } catch {
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return nil }
            markMacConnectionUnavailableIfNeeded(after: error)
            notificationSettingsLog.error("notification settings fetch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
