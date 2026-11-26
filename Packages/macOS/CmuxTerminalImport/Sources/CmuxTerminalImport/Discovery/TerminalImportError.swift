public import Foundation

/// Why a source could not be imported.
public enum TerminalImportError: Error, Equatable, Sendable {
    /// No settings for the source were found.
    case notFound(TerminalImportSource)
    /// The default Terminal profile is a built-in one whose settings are not stored.
    case builtInTerminalProfile(String)
    /// Several Warp themes exist; the user has to pick one by path.
    case warpThemeChoiceNeeded([URL])
    /// A config file exists but could not be read.
    case unreadable(URL)
    /// Ghostty's config is already loaded by cmux.
    case ghosttyAlreadyLoaded

    /// A one-line explanation for the CLI.
    public var message: String {
        switch self {
        case .notFound(let source):
            return "No \(source.displayName) settings found."
        case .builtInTerminalProfile(let name):
            return "Terminal's default profile \"\(name)\" is a built-in profile with no saved changes, so there is nothing to import."
        case .warpThemeChoiceNeeded(let urls):
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            return "Several Warp themes found (\(names)). Pass one: cmux import warp --path <theme.yaml>"
        case .unreadable(let url):
            return "Could not read \(url.path)."
        case .ghosttyAlreadyLoaded:
            return "cmux already reads your Ghostty config (~/.config/ghostty/config), so there is nothing to import."
        }
    }
}
