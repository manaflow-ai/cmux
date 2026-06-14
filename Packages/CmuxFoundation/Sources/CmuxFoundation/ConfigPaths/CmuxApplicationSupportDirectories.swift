public import Foundation

/// Resolves the Application Support base directories cmux scans for Ghostty
/// configuration, honoring `CFFIXED_USER_HOME` for test/sandbox overrides.
///
/// TRANSITIONAL: faithful lift of the app-target config-path namespace cluster
/// the engine and ``GhosttyConfig`` recurse through. These stateless directory
/// transforms have no natural receiver type; modernization into instantiated,
/// dependency-injected resolvers is deferred to the engine lift (Tranche C).
// lint:allow namespace-type — see TRANSITIONAL note above.
public enum CmuxApplicationSupportDirectories {
    /// Returns the de-duplicated, standardized Application Support directories to
    /// search, ordered from the most specific (`FileManager`-resolved) to the
    /// `~/Library/Application Support` fallback.
    public static func userDirectories(
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> [URL] {
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
