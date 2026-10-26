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
    /// Additional roots a local reply image may be read from. These stay separate from `roots` so
    /// ordinary path chips keep their project privacy gate.
    let imageRoots: [String]
    let home: String
    /// The folder a relative path starts from (the session's cwd).
    let base: String?

    init(roots: [String], imageRoots: [String] = [], home: String = NSHomeDirectory(), base: String?) {
        self.roots = roots.compactMap(AcpmuxPathPolicy.canonical).filter { $0 != "/" }
        self.imageRoots = imageRoots.compactMap(AcpmuxPathPolicy.canonical).filter { $0 != "/" }
        self.home = AcpmuxPathPolicy.canonical(home) ?? home
        self.base = base
    }

    /// A chat's folders as spelled (``AgentPaneModel/replyPathScope()``), before they are made
    /// canonical, which reads the disk.
    struct Scope: Equatable, Sendable {
        /// A chat on this Mac; a remote chat's paths are its host's, never this Mac's.
        var local: Bool
        /// The pane's roots and the folders the person added.
        var roots: [String]
        /// The folder acpmux reported for the chat's session, when the pane has it.
        var session: String?
        /// The pane's workspace root, chosen with the rest (``AgentPaneModel/primaryRoot()``).
        var primary: AgentPanePrimaryRoot
        var home: String
    }

    /// The paths of `scope`: its roots and its session's folder (never `/` or the home folder,
    /// ``AgentPaneModel/sessionRoots()``'s rule), and for images and videos also the chat's folder
    /// (the session's, else the workspace's), `/tmp` and home.
    init(_ scope: Scope) {
        let home = AcpmuxPathPolicy.canonical(NSHomeDirectory()) ?? NSHomeDirectory()
        let session = scope.session.flatMap(AcpmuxPathPolicy.canonical).flatMap { $0 != "/" && $0 != home ? $0 : nil }
        let base = session ?? scope.primary.resolve()
        guard scope.local else {
            self.init(roots: [], imageRoots: [], home: scope.home, base: nil)
            return
        }
        self.init(roots: scope.roots + (session.map { [$0] } ?? []), imageRoots: [base, "/tmp", scope.home].compactMap { $0 },
                  home: scope.home, base: base)
    }

    /// Longest path the page may send (a path is far shorter).
    static let maximumLength = 4096

    /// Raster formats the reply page recognizes as local images. Keep this list aligned with the
    /// page's `isImagePath`: the extra image roots apply only to these read-only displays.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    static func isImagePath(_ text: String) -> Bool {
        guard let path = imagePath(text) else { return false }
        return imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// The local path spelling of an image token, with URL decoration removed. Non-local file
    /// URLs are rejected before a caller can treat their path as a local file.
    static func imagePath(_ text: String) -> String? {
        if text.lowercased().hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL else { return nil }
            let host = url.host(percentEncoded: false) ?? ""
            guard host.isEmpty || host == "localhost" else { return nil }
            return url.path(percentEncoded: false)
        }
        return text.split(maxSplits: 1, whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init)
    }

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
        } else {
            // The page strips URL query and fragment text before asking the native host to
            // inspect or load a reply image. Keep native path resolution in lockstep with it.
            path = path.split(maxSplits: 1, whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? path
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

    private func isInsideRoot(_ path: String, roots: [String]) -> Bool {
        roots.contains { AcpmuxPathPolicy.contains(root: $0, path: path) }
    }

    /// The chip for `text`, nil when it is not a path. An outside path is not checked on disk, so
    /// the page never learns whether a file outside the project exists.
    private func resolve(_ text: String, inside roots: [String]) -> Resolved? {
        guard let spelled = expanded(text) else { return nil }
        if isDenied(spelled) { return Resolved(place: .denied, path: spelled, isFolder: false) }
        guard let canonical = AcpmuxPathPolicy.canonical(spelled) else {
            // Nothing there: compare its nearest existing folder, made canonical (`/var` is
            // `/private/var`), with the missing rest appended.
            let place: Place = isInsideRoot(Self.canonicalParent(spelled), roots: roots) ? .missing : .outside
            return Resolved(place: place, path: spelled, isFolder: text.hasSuffix("/"))
        }
        // A link can point a harmless name at a secret.
        if isDenied(canonical) { return Resolved(place: .denied, path: canonical, isFolder: false) }
        guard isInsideRoot(canonical, roots: roots) else { return Resolved(place: .outside, path: spelled, isFolder: text.hasSuffix("/")) }
        return Resolved(place: .root, path: canonical, isFolder: AcpmuxPathPolicy.isDirectory(canonical))
    }

    func resolve(_ text: String) -> Resolved? { resolve(text, inside: roots) }

    /// Resolves a local reply image with the chat's read-only image roots. Enforce the extension at
    /// this boundary as well as at the page call site: `image.load` is a native RPC and its `src`
    /// is untrusted. Ordinary paths never use these roots, so `/tmp` and home images do not widen
    /// the path-chip gate.
    func resolveImage(_ text: String) -> Resolved? {
        guard Self.isImagePath(text) else { return nil }
        return resolve(text, inside: roots + imageRoots)
    }

    /// Movies AVFoundation reads (``AgentPaneVideoInfo``); the page's `isVideoAttachment` names the same.
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    static func isVideoPath(_ text: String) -> Bool {
        guard let path = imagePath(text) else { return false }
        return videoExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// Resolves a video an attachment names (its poster and Quick Look) with the image roots: a
    /// screen recording lands on the Desktop, outside the project. Read-only, like an image.
    func resolveVideo(_ text: String) -> Resolved? {
        guard Self.isVideoPath(text) else { return nil }
        return resolve(text, inside: roots + imageRoots)
    }
}
