public import Foundation

/// How a custom sidebar file should be rendered.
///
/// Custom sidebars began as interpreted SwiftUI (`.swift`) with a declarative `.json` variant.
/// Both describe a *render model* of rows and sections, which is the right shape for a list of
/// workspaces but cannot express an arbitrary interface. A web source covers that case: the file
/// names a page, and the sidebar hosts it.
public enum CustomSidebarSource: Equatable, Sendable {
    /// Interpreted SwiftUI or its declarative JSON form, rendered through the interpreter.
    case interpreted(URL)
    /// A page rendered in a web view: a local `.html` document, or the target of a `.url` file.
    case web(CustomSidebarWebSource)

    /// File extensions that resolve to an interpreted source, most preferred first.
    public static let interpretedFileExtensions = ["swift", "json"]

    /// File extensions that resolve to a web source, in the order the resolver prefers them.
    public static let webFileExtensions = ["html", "url"]

    /// Every recognised custom sidebar extension, in resolution order.
    ///
    /// Interpreted sources come first, so adding a `board.html` next to an existing `board.swift`
    /// never shadows the sidebar someone already uses. Every part of cmux that resolves a sidebar
    /// name to a file — the render path, the picker scan, and the CLI's `validate` / `reload` /
    /// `select` / `open` — orders by this one list, because a name that resolves differently
    /// depending on who asked is a bug the user experiences as "the CLI opened the wrong sidebar".
    public static let fileExtensions = interpretedFileExtensions + webFileExtensions

    /// Classifies an already-resolved custom sidebar file.
    ///
    /// Returns `nil` for an unrecognised extension or a `.url` file naming nothing loadable;
    /// callers treat that as "no sidebar" rather than guessing, so a stray file in the sidebars
    /// directory cannot render as something else.
    ///
    /// The extension is matched exactly, in lowercase. Case-folding it would be friendlier right
    /// here and wrong one step later: resolution builds `<name>.<ext>` from the lowercase list
    /// while discovery reads whatever is on disk, so a folded `board.HTML` is a file the CLI lists
    /// and then cannot open on a case-sensitive volume. Refusing it outright keeps every path in
    /// agreement on every filesystem.
    public static func classify(fileURL: URL) -> CustomSidebarSource? {
        switch fileURL.pathExtension {
        case "swift", "json":
            return .interpreted(fileURL)
        case "html":
            return .web(.document(fileURL))
        case "url":
            guard let url = CustomSidebarWebSource.remoteURL(fromURLFile: fileURL) else { return nil }
            return .web(.remote(url))
        default:
            return nil
        }
    }
}
