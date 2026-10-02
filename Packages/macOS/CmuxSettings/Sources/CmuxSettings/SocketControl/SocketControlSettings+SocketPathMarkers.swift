public import Foundation

public extension SocketControlSettings {
    /// Records the active socket path to every discovery marker for the current build variant.
    ///
    /// The control socket remains authoritative in ``CmuxStateDirectory``. The
    /// app also mirrors its absolute path into the legacy Application Support
    /// marker so external clients using the pre-0.64.20 discovery contract keep
    /// following the live listener without creating a second socket.
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

    /// The marker file paths that advertise the live socket for the current build variant.
    /// - Parameters:
    ///   - bundleIdentifier: The running app's bundle identifier.
    ///   - environment: The process environment.
    ///   - fileManager: The file manager used to resolve current and legacy marker
    ///     directories; defaults to `.default`.
    /// - Returns: The marker file paths to write.
    static func lastSocketPathFiles(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [String] {
        (
            SocketPathMarkerFiles.paths(
                bundleIdentifier: bundleIdentifier,
                environment: environment,
                directory: stableSocketDirectoryURL(fileManager: fileManager),
                baseDebugBundleIdentifier: baseDebugBundleIdentifier
            ) + SocketPathMarkerFiles.paths(
                bundleIdentifier: bundleIdentifier,
                environment: environment,
                directory: CmuxStateDirectory.legacyApplicationSupportURL(fileManager: fileManager),
                baseDebugBundleIdentifier: baseDebugBundleIdentifier
            )
        ).reduce(into: (seen: Set<String>(), paths: [String]())) { result, path in
            if result.seen.insert(path).inserted {
                result.paths.append(path)
            }
        }.paths
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
