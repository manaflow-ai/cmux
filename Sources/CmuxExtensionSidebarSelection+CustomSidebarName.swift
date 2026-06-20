import Foundation
import CmuxSettings
import CmuxSidebarProviderKit

#if DEBUG
private enum CustomSidebarDirectoryOverrideForTesting {
    @TaskLocal static var value: URL?
}
#endif

extension CmuxExtensionSidebarSelection {
    /// Provider-id prefix for user/agent-authored custom sidebars. The
    /// suffix after the prefix is the sidebar's file base name.
    static let customSidebarProviderPrefix = "cmux.sidebar.custom."

    /// Synchronous read of the experimental custom-sidebars flag, mirroring
    /// ``isEnabled`` for the AppKit/static paths (the picker menu).
    static var customSidebarsEnabled: Bool {
        // See ``isEnabled``: read only the beta-features section so a body-path
        // access does not allocate the entire `SettingCatalog` (issue #5970).
        let key = BetaFeaturesCatalogSection().customSidebars
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey)) ?? key.defaultValue
    }

    /// Directory custom sidebars are authored into.
    static var customSidebarsDirectory: URL {
        #if DEBUG
        if let override = customSidebarsDirectoryOverrideForTesting { return override }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/sidebars", isDirectory: true)
    }

    /// One provider descriptor per `<name>.swift`/`<name>.html`/`<name>.json`
    /// file in the sidebars directory (`.swift` preferred, then `.html`, then
    /// `.json` when more than one exists), titled by the file's base name.
    static var customSidebarDescriptors: [CmuxSidebarProviderDescriptor] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: customSidebarsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var extensionByName: [String: String] = [:]
        for url in entries {
            let ext = url.pathExtension.lowercased()
            guard ext == "swift" || ext == "html" || ext == "json" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if customSidebarFileExtensionPriority(extensionByName[name]) < customSidebarFileExtensionPriority(ext) {
                continue
            }
            extensionByName[name] = ext
        }
        return extensionByName.keys.sorted().map { name in
            CmuxSidebarProviderDescriptor(
                id: customSidebarProviderPrefix + name,
                title: CmuxSidebarProviderLocalizedText(key: "sidebar.provider.custom.\(name)", defaultValue: name),
                subtitle: CmuxSidebarProviderLocalizedText(
                    key: "sidebar.provider.custom.subtitle",
                    defaultValue: String(localized: "sidebar.provider.custom.subtitle", defaultValue: "Custom sidebar")
                ),
                systemImageName: "wand.and.stars",
                isHostProvided: false
            )
        }
    }

    /// Resolves a custom-sidebar provider id to its backing file URL
    /// (`.swift`, then `.html`, then `.json`), or `nil` if no file exists.
    static func customSidebarFileURL(forProviderId providerId: String) -> URL? {
        customSidebarFileURL(forProviderId: providerId, sidebarsDirectory: customSidebarsDirectory)
    }

    static func customSidebarFileURL(forProviderId providerId: String, sidebarsDirectory: URL) -> URL? {
        guard providerId.hasPrefix(customSidebarProviderPrefix) else { return nil }
        let name = String(providerId.dropFirst(customSidebarProviderPrefix.count))
        guard isValidCustomSidebarFileBaseName(name) else { return nil }
        let swiftURL = sidebarsDirectory.appendingPathComponent("\(name).swift", isDirectory: false)
        if FileManager.default.fileExists(atPath: swiftURL.path) { return swiftURL }
        let htmlURL = sidebarsDirectory.appendingPathComponent("\(name).html", isDirectory: false)
        if FileManager.default.fileExists(atPath: htmlURL.path) { return htmlURL }
        let jsonURL = sidebarsDirectory.appendingPathComponent("\(name).json", isDirectory: false)
        if FileManager.default.fileExists(atPath: jsonURL.path) { return jsonURL }
        return nil
    }

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

    private static func customSidebarFileExtensionPriority(_ pathExtension: String?) -> Int {
        switch pathExtension?.lowercased() {
        case "swift":
            return 0
        case "html":
            return 1
        case "json":
            return 2
        default:
            return Int.max
        }
    }

    private static func isValidCustomSidebarFileBaseName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return name == (name as NSString).lastPathComponent
    }
}
