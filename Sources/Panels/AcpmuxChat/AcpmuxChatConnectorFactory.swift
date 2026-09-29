import CmuxAcpmux
import CmuxSettings
import Foundation

/// Builds the acpmux connector for this app instance: the shared user daemon for release
/// builds, a private daemon under the tag's Application Support directory for DEV tags.
struct AcpmuxChatConnectorFactory {
    let bundle: Bundle
    let processEnvironment: [String: String]
    let fileManager: FileManager

    func makeConnector() -> AcpmuxDaemonConnector {
        let bundleID = bundle.bundleIdentifier ?? "com.cmuxterm.app"
        let applicationSupport = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent(bundleID, isDirectory: true)
        let environment = AcpmuxDaemonEnvironment.resolve(
            tag: tag(bundleID: bundleID),
            bundledExecutable: bundle.url(forResource: "acpmux", withExtension: nil, subdirectory: "bin"),
            applicationSupportDirectory: applicationSupport,
            processEnvironment: processEnvironment,
            userHome: fileManager.homeDirectoryForCurrentUser,
            userID: getuid()
        )
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return AcpmuxDaemonConnector(
            environment: environment,
            launcher: AcpmuxDaemonLauncher(userHome: fileManager.homeDirectoryForCurrentUser, baseEnvironment: processEnvironment),
            clientName: "cmux",
            clientVersion: version
        )
    }

    /// The DEV tag from `CMUX_TAG`, or from a `com.cmuxterm.app.debug.<tag>` bundle id.
    private func tag(bundleID: String) -> String? {
        if let tag = SocketControlSettings.launchTag(environment: processEnvironment) { return tag }
        let prefix = SocketControlSettings.baseDebugBundleIdentifier + "."
        guard bundleID.hasPrefix(prefix) else { return nil }
        let tag = String(bundleID.dropFirst(prefix.count))
        return tag.isEmpty ? nil : tag
    }
}
