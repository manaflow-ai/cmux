import Foundation
import CmuxSidebar

#if DEBUG
private enum CustomSidebarDirectoryOverrideForTesting {
    @TaskLocal static var value: URL?
}
#endif

extension CmuxExtensionSidebarSelection {
    #if DEBUG
    static var customSidebarsDirectoryOverrideForTesting: URL? {
        CustomSidebarDirectoryOverrideForTesting.value
    }

    static func withCustomSidebarsDirectoryForTesting<T>(_ directory: URL, _ body: () throws -> T) rethrows -> T {
        try CustomSidebarDirectoryOverrideForTesting.$value.withValue(directory) {
            try body()
        }
    }
    #endif

    /// Resolves the custom-sidebars directory. Our refactor made
    /// `customSidebarsDirectory`/`customSidebarFileURL(forProviderId:)` instance
    /// members on the package type, so these static helpers reach them through a
    /// throwaway instance (honoring the DEBUG test override).
    private static var resolvedCustomSidebarsDirectory: URL {
        #if DEBUG
        if let override = customSidebarsDirectoryOverrideForTesting { return override }
        #endif
        return CmuxExtensionSidebarSelection().customSidebarsDirectory
    }

    static func customSidebarFileURL(forName name: String) -> URL? {
        customSidebarFileURL(forName: name, sidebarsDirectory: resolvedCustomSidebarsDirectory)
    }

    static func customSidebarFileURL(forName name: String, sidebarsDirectory: URL) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return CmuxExtensionSidebarSelection().customSidebarFileURL(
            forProviderId: customSidebarProviderPrefix + trimmed,
            sidebarsDirectory: sidebarsDirectory
        )
    }
}
