import CmuxNextCloud
import CmuxNextControl
import CmuxNextMobileConnect
import Foundation

/// Builds the phone link's account (`MobileLinkHostAccount`) from the
/// signed-in cmux account: the Stack session registers this Mac's install
/// once, the install key and record live where the irx host keeps its v2
/// keys (files under the bundle's state directory in DEV builds, the login
/// Keychain in release builds), and the API Worker is the feed's
/// (`FeedService.apiBaseURL`).
enum CloudMobileLinkAccount {
    /// Nil unless signed in with a user.
    @MainActor static func make(auth: CloudAuth, apiBaseURL: URL, launch: LaunchIdentity, macName: String)
        -> InstallHostAccount? {
        guard auth.isSignedIn, let user = auth.user?.id else { return nil }
        let namespace = launch.bundleID ?? "com.cmuxterm.app.next"
        let host = apiBaseURL.host ?? "api"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("mobile-link", isDirectory: true)
        #if DEBUG
        let storage = MacInstallKeyStorage.file(directory.appendingPathComponent("install-key-\(host)"))
        #else
        let storage = MacInstallKeyStorage.keychain(service: "\(namespace).install-key.\(host)")
        #endif
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return InstallHostAccount(
            apiBaseURL: apiBaseURL, stackUser: user,
            sessionToken: { try await auth.tokens().access },
            deviceName: macName, clientVersion: version, key: MacInstallKey(storage: storage),
            records: MacInstallRecordStore(file: directory.appendingPathComponent("install-records-\(host).json")),
            macName: { await MacName.computerName() },
            isCurrent: { await MainActor.run { auth.isSignedIn && auth.user?.id == user } })
    }
}
