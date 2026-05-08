import Foundation

nonisolated public struct CmxDesktopRuntimePaths: Equatable, Sendable {
    public var stateDirectory: URL
    public var nativeSocketPath: String
    public var compatibilitySocketPath: String

    public init(
        stateDirectory: URL,
        nativeSocketPath: String,
        compatibilitySocketPath: String
    ) {
        self.stateDirectory = stateDirectory
        self.nativeSocketPath = nativeSocketPath
        self.compatibilitySocketPath = compatibilitySocketPath
    }
}

nonisolated public enum CmxDesktopRuntimePathResolver {
    public static func resolve(
        tag: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = URL(fileURLWithPath: "/tmp", isDirectory: true)
    ) -> CmxDesktopRuntimePaths {
        if let slug = sanitizedTag(tag), !slug.isEmpty {
            let root = temporaryDirectory.appendingPathComponent("cmux-cmx-\(slug)", isDirectory: true)
            return CmxDesktopRuntimePaths(
                stateDirectory: root.appendingPathComponent("cmx-state", isDirectory: true),
                nativeSocketPath: "/tmp/cmux-cmx-\(slug)/native.sock",
                compatibilitySocketPath: "/tmp/cmux-debug-\(slug).sock"
            )
        }

        let stateDirectory = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("cmx", isDirectory: true)

        return CmxDesktopRuntimePaths(
            stateDirectory: stateDirectory,
            nativeSocketPath: "/tmp/cmux-cmx-native.sock",
            compatibilitySocketPath: "/tmp/cmux.sock"
        )
    }

    public static func sanitizedTag(_ tag: String?) -> String? {
        guard let tag = tag?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tag.isEmpty else {
            return nil
        }
        return tag.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        .map(String.init)
        .joined()
    }
}
