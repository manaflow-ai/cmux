import Foundation

extension CmuxExtensionSidebarSelection {
    #if DEBUG
    static var customSidebarsDirectoryOverrideForTesting: URL?

    static func withCustomSidebarsDirectoryForTesting<T>(_ directory: URL, _ body: () throws -> T) rethrows -> T {
        let previous = customSidebarsDirectoryOverrideForTesting
        customSidebarsDirectoryOverrideForTesting = directory
        defer { customSidebarsDirectoryOverrideForTesting = previous }
        return try body()
    }
    #endif

    static func customSidebarFileURL(forName name: String) -> URL? {
        customSidebarFileURL(forName: name, sidebarsDirectory: customSidebarsDirectory)
    }

    static func customSidebarFileURL(forName name: String, sidebarsDirectory: URL) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return customSidebarFileURL(
            forProviderId: customSidebarProviderPrefix + trimmed,
            sidebarsDirectory: sidebarsDirectory
        )
    }
}
