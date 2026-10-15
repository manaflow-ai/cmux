public import Foundation

/// What an unpacked extension's manifest says it can reach, as consent-sheet
/// permission lines.
///
/// Chromium localizes permission warnings only for installs it prompts for;
/// a CLI "load unpacked" request has no Chromium prompt, so cmux summarizes
/// the manifest itself: the sites it can read and change (host permissions
/// and content scripts) and the API permissions it declares.
public struct BrowserExtensionManifestSummary: Equatable, Sendable {
    /// The extension name from the manifest (unlocalized `__MSG_` names stay as written).
    public var name: String
    /// The consent lines.
    public var permissions: [BrowserExtensionInstallPrompt.Permission]

    /// Summarizes a parsed `manifest.json`.
    ///
    /// - Parameter manifest: The parsed manifest.
    public init(manifest: [String: Any]) {
        name = manifest["name"] as? String ?? ""
        var lines: [BrowserExtensionInstallPrompt.Permission] = []
        let hosts = Array(Set(BrowserExtensionAgentAccess.patterns(manifest))).sorted()
        if hosts.contains("<all_urls>") || hosts.contains(where: { $0.hasPrefix("*://*/") || $0.contains("://*/") }) {
            lines.append(.init(message: String(localized: "browser.extension.manifest.allSites",
                                               defaultValue: "Read and change all your data on all websites", bundle: .module)))
        } else if !hosts.isEmpty {
            lines.append(.init(message: String(localized: "browser.extension.manifest.someSites",
                                               defaultValue: "Read and change your data on these sites:", bundle: .module),
                               details: hosts.joined(separator: "\n")))
        }
        let api = ((manifest["permissions"] as? [Any] ?? []) + (manifest["optional_permissions"] as? [Any] ?? []))
            .compactMap { $0 as? String }
            .filter { $0 != "<all_urls>" && !$0.contains("://") }
        if !api.isEmpty {
            lines.append(.init(message: String(localized: "browser.extension.manifest.api",
                                               defaultValue: "Use these browser features:", bundle: .module),
                               details: Array(Set(api)).sorted().joined(separator: ", ")))
        }
        permissions = lines
    }

    /// Reads and summarizes `<folder>/manifest.json`.
    ///
    /// - Parameter folder: The unpacked extension folder.
    /// - Returns: nil when the manifest is missing or unreadable.
    public static func read(folder: String) -> BrowserExtensionManifestSummary? {
        let file = (folder as NSString).appendingPathComponent("manifest.json")
        guard let data = FileManager.default.contents(atPath: file),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return BrowserExtensionManifestSummary(manifest: object)
    }
}
