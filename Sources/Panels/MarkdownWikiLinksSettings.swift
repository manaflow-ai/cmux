import Foundation

/// Persistent toggle for wiki-style link parsing in the markdown viewer.
///
/// Backed by the `markdown.wikiLinks` key, shared by the Settings window
/// (`CmuxSettings` catalog), the `~/.config/cmux/cmux.json` parser, and the
/// `MarkdownWebRenderer`. `false` preserves the default markdown behavior where
/// `[[...]]` renders as literal text; `true` turns `[[Note]]` /
/// `[[Note|Label]]` into links to sibling markdown files.
enum MarkdownWikiLinksSettings {
    /// UserDefaults / cmux.json key.
    static let key = "markdown.wikiLinks"

    /// Default state: wiki links off, matching standard markdown.
    static let defaultEnabled = false

    /// Whether wiki-link parsing is currently enabled, honoring the stored
    /// override and falling back to ``defaultEnabled``.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? defaultEnabled : defaults.bool(forKey: key)
    }
}
