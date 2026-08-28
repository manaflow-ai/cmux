import Foundation

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

    /// The sidebar name a custom-sidebar provider id refers to, or `nil` when the id is not one.
    ///
    /// The rail resolves by name on every reload rather than holding a file, so it needs the name
    /// the provider id encodes. Extracting it here keeps the prefix known to one file.
    static func customSidebarName(forProviderId providerId: String) -> String? {
        guard providerId.hasPrefix(customSidebarProviderPrefix) else { return nil }
        let name = String(providerId.dropFirst(customSidebarProviderPrefix.count))
        return name.isEmpty ? nil : name
    }

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
