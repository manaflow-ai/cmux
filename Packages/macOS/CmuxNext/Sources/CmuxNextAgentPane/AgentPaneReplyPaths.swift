import Foundation

/// Where a path that a reply names is, for its chip (decision D4). The path is untrusted reply
/// text, so the host decides, never the page: the path is expanded (`~/`, a relative path from
/// the session's folder), made canonical (symlinks and `..` resolved, ``AcpmuxPathPolicy``), and
/// compared with the session's folders by path components.
nonisolated struct AgentPaneReplyPaths {
    enum Place: String, Equatable, Sendable {
        /// Inside a root: the chip opens it.
        case root
        /// Outside every root: the chip has a lock and follows `agentPane.links.outsideRoots`.
        case outside
        /// On the deny list: plain text, never an action.
        case denied
        /// Inside a root, but nothing is there: plain text.
        case missing
    }

    struct Resolved: Equatable, Sendable {
        var place: Place
        /// The path to act on: canonical when it exists, else the expanded spelling.
        var path: String
        /// A folder (shown with the folder glyph; opens in Finder).
        var isFolder: Bool
    }

    /// The canonical roots (`/` counts as no root).
    let roots: [String]
    let home: String
    /// The folder a relative path starts from (the session's cwd).
    let base: String?

    init(roots: [String], home: String = NSHomeDirectory(), base: String?) {
        self.roots = roots.compactMap(AcpmuxPathPolicy.canonical).filter { $0 != "/" }
        self.home = AcpmuxPathPolicy.canonical(home) ?? home
        self.base = base
    }

    /// Longest path the page may send (a path is far shorter).
    static let maximumLength = 4096

    /// Folders under the home folder that hold credentials, and file names that are secrets. A
    /// path in one of them, or a name that matches, is never a chip (D4).
    static let deniedFolders = [".ssh", ".gnupg", "Library/Keychains", ".aws", ".config/gh"]

    static func isDeniedName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".pem") || lower.hasSuffix(".key") || lower.hasPrefix(".env")
    }

    /// The absolute path `text` names, before symlinks: `~/` from home, a relative path from
    /// ``base``, `file://` URLs decoded, `..` and `.` removed. Nil for text that is not a path.
    func expanded(_ text: String) -> String? {
        guard !text.isEmpty, text.utf8.count <= Self.maximumLength, !text.utf8.contains(0) else { return nil }
        var path = text
        if path.lowercased().hasPrefix("file://") {
            guard let url = URL(string: path), url.isFileURL, url.host(percentEncoded: false).map({ $0.isEmpty || $0 == "localhost" }) ?? true
            else { return nil }
            path = url.path(percentEncoded: false)
        }
        if path == "~" || path.hasPrefix("~/") {
            path = home + path.dropFirst()
        } else if !path.hasPrefix("/") {
            guard let base, base.hasPrefix("/") else { return nil }
            path = base + "/" + path
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Whether `path` (absolute) is on the deny list, by its spelling.
    func isDenied(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if Self.isDeniedName(name) { return true }
        return Self.deniedFolders.contains { folder in
            AcpmuxPathPolicy.contains(root: home + "/" + folder, path: path)
        }
    }

    /// `path` with its deepest existing folder made canonical and the rest kept as spelled.
    static func canonicalParent(_ path: String) -> String {
        var head = path
        var rest: [String] = []
        while head != "/", !head.isEmpty {
            if let canonical = AcpmuxPathPolicy.canonical(head) {
                return ([canonical == "/" ? "" : canonical] + rest.reversed()).joined(separator: "/")
            }
            rest.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
        return path
    }

    func isInsideRoot(_ path: String) -> Bool {
        roots.contains { AcpmuxPathPolicy.contains(root: $0, path: path) }
    }

    /// The chip for `text`, nil when it is not a path. An outside path is not checked on disk, so
    /// the page never learns whether a file outside the project exists.
    func resolve(_ text: String) -> Resolved? {
        guard let spelled = expanded(text) else { return nil }
        if isDenied(spelled) { return Resolved(place: .denied, path: spelled, isFolder: false) }
        guard let canonical = AcpmuxPathPolicy.canonical(spelled) else {
            // Nothing there: compare its nearest existing folder, made canonical (`/var` is
            // `/private/var`), with the missing rest appended.
            let place: Place = isInsideRoot(Self.canonicalParent(spelled)) ? .missing : .outside
            return Resolved(place: place, path: spelled, isFolder: text.hasSuffix("/"))
        }
        // A link can point a harmless name at a secret.
        if isDenied(canonical) { return Resolved(place: .denied, path: canonical, isFolder: false) }
        guard isInsideRoot(canonical) else { return Resolved(place: .outside, path: spelled, isFolder: text.hasSuffix("/")) }
        return Resolved(place: .root, path: canonical, isFolder: AcpmuxPathPolicy.isDirectory(canonical))
    }
}
