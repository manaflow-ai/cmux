import CmuxSettings
import Foundation

/// Runtime reader for where a Cmd-clicked file path link in the markdown
/// viewer opens. Backed by the `markdown.cmdClickOpenTarget` key in
/// `cmux.json` / Settings (see `MarkdownCatalogSection.cmdClickOpenTarget`).
enum MarkdownCmdClickOpenSettings {
    /// UserDefaults / cmux.json key (`markdown.cmdClickOpenTarget`).
    static let key = "markdown.cmdClickOpenTarget"
    static let defaultTarget: MarkdownCmdClickOpenTarget = .newTab

    /// Strict raw-value decode for config validation; `nil` for unknown values.
    static func validTarget(rawValue: String) -> MarkdownCmdClickOpenTarget? {
        MarkdownCmdClickOpenTarget(rawValue: rawValue)
    }

    static func target(for rawValue: String?) -> MarkdownCmdClickOpenTarget {
        rawValue.flatMap(MarkdownCmdClickOpenTarget.init(rawValue:)) ?? defaultTarget
    }

    static func target(defaults: UserDefaults = .standard) -> MarkdownCmdClickOpenTarget {
        target(for: defaults.string(forKey: key))
    }
}
