import Foundation

/// Reads the `markdown.wikiLinkAnchor` preference — which marker folder anchors
/// the top of the note collection for wiki-link resolution.
///
/// Kept as a thin string reader (decoupled from the `CmuxSettings` enum) so the
/// markdown renderer can resolve the marker folder name without importing the
/// settings catalog. Values round-trip with `MarkdownWikiLinkAnchor`.
enum MarkdownWikiLinkAnchorSettings {
    /// UserDefaults / cmux.json key.
    static let key = "markdown.wikiLinkAnchor"

    /// Default anchor: the Obsidian vault marker.
    static let defaultMarkerName = ".obsidian"

    /// The marker folder name to look for in ancestor directories, honoring the
    /// stored preference and falling back to ``defaultMarkerName``.
    static func markerFolderName(defaults: UserDefaults = .standard) -> String {
        switch defaults.string(forKey: key) {
        case "git": return ".git"
        case "obsidian": return ".obsidian"
        default: return defaultMarkerName
        }
    }
}
