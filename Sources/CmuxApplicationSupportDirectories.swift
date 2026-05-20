import Foundation

enum CmuxApplicationSupportDirectories {
    static func userDirectories(
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

        if let fixedHome = environment["CFFIXED_USER_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fixedHome.isEmpty {
            append(
                URL(fileURLWithPath: fixedHome, isDirectory: true)
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            )
        }

        if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty {
            append(
                URL(fileURLWithPath: home, isDirectory: true)
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            )
        }

        append(fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)

        append(
            URL(
                fileURLWithPath: NSString(string: "~/Library/Application Support").expandingTildeInPath,
                isDirectory: true
            )
        )

        return urls
    }
}
