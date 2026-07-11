import Foundation

/// The bundle-scoped directory that stores agent hook session records.
public struct AgentHookStateLocation: Sendable, Equatable {
    /// The directory used by hook writers and app-side readers.
    public let directoryURL: URL

    /// Creates a bundle-scoped hook state location.
    ///
    /// - Parameters:
    ///   - applicationSupportDirectory: The user's Application Support directory.
    ///   - bundleIdentifier: The running app's bundle identifier.
    public init?(applicationSupportDirectory: URL, bundleIdentifier: String?) {
        guard let bundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleIdentifier.isEmpty else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let safeBundleIdentifier = bundleIdentifier.map { character -> Character in
            character.unicodeScalars.allSatisfy { allowed.contains($0) } ? character : "-"
        }
        directoryURL = applicationSupportDirectory
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-hooks", isDirectory: true)
            .appendingPathComponent(String(safeBundleIdentifier), isDirectory: true)
    }

    /// Resolves the hook state directory used by both agent hooks and app readers.
    public static func resolveDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        legacyHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["CMUX_AGENT_HOOK_STATE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty {
            return URL(
                fileURLWithPath: NSString(string: override).expandingTildeInPath,
                isDirectory: true
            )
        }
        if let applicationSupportDirectory,
           let location = AgentHookStateLocation(
               applicationSupportDirectory: applicationSupportDirectory,
               bundleIdentifier: bundleIdentifier
           ) {
            return location.directoryURL
        }
        return legacyHomeDirectory.appendingPathComponent(".cmuxterm", isDirectory: true)
    }
}
