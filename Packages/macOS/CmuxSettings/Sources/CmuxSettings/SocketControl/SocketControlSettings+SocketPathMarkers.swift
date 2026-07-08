public import Foundation

public extension SocketControlSettings {
    /// Records the active socket path to every marker file for the current build variant.
    /// - Parameters:
    ///   - path: The socket path to record.
    ///   - bundleIdentifier: The running app's bundle identifier.
    ///   - environment: The process environment.
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

    /// The marker file paths that record the last socket path for the current build variant.
    /// - Parameters:
    ///   - bundleIdentifier: The running app's bundle identifier.
    ///   - environment: The process environment.
    ///   - fileManager: The file manager used to resolve the cmux state directory; defaults to `.default`.
    /// - Returns: The marker file paths to write.
    static func lastSocketPathFiles(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [String] {
        SocketPathMarkerFiles.paths(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            directory: stableSocketDirectoryURL(fileManager: fileManager),
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
