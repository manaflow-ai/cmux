import Foundation

extension CmuxExtensionSidebarSelection {
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
