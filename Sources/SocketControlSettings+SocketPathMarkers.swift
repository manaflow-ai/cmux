import CMUXSocketPathDomain
import Foundation

extension SocketControlSettings {
    static func recordLastSocketPath(
        _ path: String,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let payload = Data((path + "\n").utf8)
        for filePath in lastSocketPathFiles(bundleIdentifier: bundleIdentifier, environment: environment) {
            writeSocketPathMarker(payload, to: filePath)
        }
    }

    static func lastSocketPathFiles(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [String] {
        SocketPathMarkerFiles.paths(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            appSupportDirectory: stableSocketDirectoryURL(fileManager: fileManager),
            baseDebugBundleIdentifier: baseDebugBundleIdentifier
        )
    }

    private static func writeSocketPathMarker(_ payload: Data, to filePath: String) {
        let fileURL = URL(fileURLWithPath: filePath)
        let parentURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? payload.write(to: fileURL, options: .atomic)
    }
}
