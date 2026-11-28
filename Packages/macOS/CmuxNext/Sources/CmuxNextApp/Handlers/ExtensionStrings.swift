import Foundation

/// Chrome extension action results and dialog text. Keys live in
/// Resources/Extensions.xcstrings.
enum ExtensionStrings {
    static var needsChromiumTab: String { String(localized: "extensions.failed.needsChromiumTab", defaultValue: "Focus a Chromium tab first; extensions run in Chromium tabs.", table: "Extensions", bundle: .module) }
    static var needsFork: String { String(localized: "extensions.failed.needsFork", defaultValue: "This Chromium runtime cannot manage extensions; use Manage Extensions.", table: "Extensions", bundle: .module) }
    static var needsPane: String { String(localized: "extensions.failed.needsPane", defaultValue: "No pane is focused.", table: "Extensions", bundle: .module) }
    static var refused: String { String(localized: "extensions.failed.refused", defaultValue: "Chromium refused the change (policy, or the extension cannot be changed).", table: "Extensions", bundle: .module) }
    static var noOptions: String { String(localized: "extensions.failed.noOptions", defaultValue: "This extension has no options page.", table: "Extensions", bundle: .module) }
    static var commandFailed: String { String(localized: "extensions.failed.command", defaultValue: "The extension shortcut could not run.", table: "Extensions", bundle: .module) }
    static var chooseFolder: String { String(localized: "extensions.panel.chooseFolder", defaultValue: "Choose an unpacked extension folder (it contains manifest.json).", table: "Extensions", bundle: .module) }
    static var load: String { String(localized: "extensions.panel.load", defaultValue: "Load", table: "Extensions", bundle: .module) }

    static func unknownExtension(_ text: String) -> String {
        String(format: String(localized: "extensions.failed.unknown", defaultValue: "No installed extension matches “%@”.", table: "Extensions", bundle: .module), text)
    }

    static func noManifest(_ path: String) -> String {
        String(format: String(localized: "extensions.failed.noManifest", defaultValue: "%@ has no manifest.json.", table: "Extensions", bundle: .module), path)
    }
}
