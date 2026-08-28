public import Foundation

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
    ///
    /// The target must also name a host. `http:` and `http:///path` parse cleanly and report the
    /// right scheme, so a scheme-only check accepts them — and then there is nothing to fetch, so
    /// the sidebar mounts and renders blank with no error anywhere for the author to find.
    ///
    /// The file is read through ``CustomSidebarURLFileReader``, which bounds it: a `.url` file past
    /// the limit names nothing, however good its first line is.
    public static func remoteURL(fromURLFile fileURL: URL) -> URL? {
        guard case let .lines(lines) = CustomSidebarURLFileReader.read(fileURL: fileURL) else {
            return nil
        }
        for candidate in lines {
            guard let url = URL(string: candidate), isLoadable(url) else { continue }
            return url
        }
        return nil
    }

    /// Whether a URL is one a sidebar may load: `http`/`https` with a non-empty host.
    ///
    /// Shared with ``CustomSidebarWebSourceProblem`` so the "which URL" and "why not" answers cannot
    /// disagree about the same file.
    static func isLoadable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }
}
