public import Foundation

/// Resolves the Application Support base directories cmux scans for Ghostty
/// configuration, honoring `CFFIXED_USER_HOME` for test/sandbox overrides.
/// Construct it with the process environment and read ``userDirectories``.
public struct CmuxApplicationSupportDirectories {
    private let environment: [String: String]
    private let fileManager: FileManager

    public init(
        environment: [String: String],
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
    }

    /// The de-duplicated, standardized Application Support directories to search,
    /// ordered from the most specific (`FileManager`-resolved) to the
    /// `~/Library/Application Support` fallback.
    public var userDirectories: [URL] {
        var urls: [URL] = []
        var seen: Set<String> = []

        func append(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                urls.append(standardized)
            }
        }

        append(fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)

        if let fixedHome = environment["CFFIXED_USER_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fixedHome.isEmpty {
            append(
                URL(fileURLWithPath: fixedHome, isDirectory: true)
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            )
        }

        append(
            URL(
                fileURLWithPath: NSString(string: "~/Library/Application Support").expandingTildeInPath,
                isDirectory: true
            )
        )

        return urls
    }
}
