import Foundation

extension CmuxExtensionSidebarSelection {
    #if DEBUG
    private static let customSidebarsDirectoryOverrideLock = NSRecursiveLock()
    private static var customSidebarsDirectoryOverrideStorage: URL?

    private(set) static var customSidebarsDirectoryOverrideForTesting: URL? {
        get {
            customSidebarsDirectoryOverrideLock.lock()
            defer { customSidebarsDirectoryOverrideLock.unlock() }
            return customSidebarsDirectoryOverrideStorage
        }
        set {
            customSidebarsDirectoryOverrideLock.lock()
            defer { customSidebarsDirectoryOverrideLock.unlock() }
            customSidebarsDirectoryOverrideStorage = newValue
        }
    }

    static func withCustomSidebarsDirectoryForTesting<T>(_ directory: URL, _ body: () throws -> T) rethrows -> T {
        customSidebarsDirectoryOverrideLock.lock()
        let previous = customSidebarsDirectoryOverrideStorage
        customSidebarsDirectoryOverrideStorage = directory
        defer {
            customSidebarsDirectoryOverrideStorage = previous
            customSidebarsDirectoryOverrideLock.unlock()
        }
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
