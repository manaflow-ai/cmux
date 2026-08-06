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

    /// File extensions that resolve to a web source, in the order the resolver prefers them.
    public static let webFileExtensions = ["html", "url"]

    /// Classifies an already-resolved custom sidebar file.
    ///
    /// Returns `nil` only for an unrecognised extension; callers treat that as "no sidebar" rather
    /// than guessing, so a stray file in the sidebars directory cannot render as something else.
    public static func classify(fileURL: URL) -> CustomSidebarSource? {
        switch fileURL.pathExtension.lowercased() {
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

/// The page a web-backed custom sidebar shows.
public enum CustomSidebarWebSource: Equatable, Sendable {
    /// A local HTML document, loaded with read access limited to its own directory.
    case document(URL)
    /// An `http` or `https` page named by a `.url` file — typically a local dev server.
    case remote(URL)

    /// Reads the URL out of a `.url` file.
    ///
    /// The file is plain text holding one URL. Windows-style `[InternetShortcut]` files are also
    /// accepted by taking the `URL=` line, since that is what a browser writes when you drag a
    /// page to disk and users will reasonably expect it to work.
    ///
    /// Only `http` and `https` are honoured. A `file://` target would let a dropped shortcut read
    /// anything on disk from inside the app's own window, and custom schemes can hand off to other
    /// applications entirely.
    public static func remoteURL(fromURLFile fileURL: URL) -> URL? {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("[") || line.hasPrefix("#") { continue }
            let candidate = line.hasPrefix("URL=") ? String(line.dropFirst(4)) : line
            guard let url = URL(string: candidate.trimmingCharacters(in: .whitespaces)),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { continue }
            return url
        }
        return nil
    }
}
