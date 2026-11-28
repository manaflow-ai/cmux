public import Foundation
import UniformTypeIdentifiers

/// What cmux does with a URL or file macOS hands it (it is the default
/// browser, the `ssh:` or `x-man-page:` handler, the opener of a file type in
/// Info.plist, or the target of the Finder service "New cmux Tab Here").
public nonisolated enum ExternalOpenRoute: Equatable, Sendable {
    /// A browser tab in the current window's focused pane.
    case browserTab(URL)
    /// A terminal tab in the current window's focused pane, started in
    /// `cwd`, then `command` typed into its shell (already shell-quoted).
    case terminal(cwd: String?, command: String?)
    /// Any other file: the shared file opener (`file.open`), which shows
    /// Markdown in the Markdown page, text and code in the code editor page,
    /// and images, PDFs and media in a browser tab.
    case file(URL)
    /// A link in this build's scheme (`cmux://tab/…`): the caller runs the
    /// `link.open` action with it, which only navigates.
    case deepLink(URL)
    /// Not something cmux opens; the caller refuses it.
    case unsupported
}

/// Maps opened URLs and files to routes. Pure: no AppKit, no file writes;
/// `isDirectory` and `isExecutable` are injected for tests.
public nonisolated struct ExternalOpenRouter: Sendable {
    public var isDirectory: @Sendable (String) -> Bool
    public var isExecutable: @Sendable (String) -> Bool
    /// This build's URL scheme (`cmux`, `cmux-dev`, `cmux-dev-<tag>`), the
    /// one sign-in calls back on; nil routes no links.
    public var linkScheme: String?
    /// Whether a URL is the sign-in callback, which goes to auth, never to a
    /// link. The App passes Cloud auth's own matcher; the default accepts
    /// the same host and path forms (``isSignInCallback(_:)``).
    public var isAuthCallback: @Sendable (URL) -> Bool

    /// The sign-in callback's target, as host or path.
    static let authCallbackTarget = "auth-callback"

    /// The sign-in callback in any form auth accepts: `<scheme>://auth-callback`,
    /// `<scheme>:auth-callback` and `<scheme>:///auth-callback`.
    public static func isSignInCallback(_ url: URL) -> Bool {
        let slashes = CharacterSet(charactersIn: "/")
        if let host = url.host(percentEncoded: false)?.trimmingCharacters(in: slashes), !host.isEmpty {
            return host.lowercased() == authCallbackTarget
        }
        return url.path.trimmingCharacters(in: slashes).lowercased() == authCallbackTarget
    }

    public init(
        linkScheme: String? = nil,
        isAuthCallback: @escaping @Sendable (URL) -> Bool = { ExternalOpenRouter.isSignInCallback($0) },
        isDirectory: @escaping @Sendable (String) -> Bool = { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        },
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.linkScheme = linkScheme
        self.isAuthCallback = isAuthCallback
        self.isDirectory = isDirectory
        self.isExecutable = isExecutable
    }

    /// Script extensions and the shell that runs a script without its execute bit.
    /// The terminal script extensions (`.command`, `.tool`, `.sh`, `.zsh`,
    /// `.csh`, `.pl`, `.bash`).
    static let scriptShells = ["command": "sh", "tool": "sh", "sh": "sh", "zsh": "zsh", "bash": "bash", "csh": "csh", "pl": "perl"]
    /// Files a browser opens as a page: web pages, SVG and saved pages.
    static let pageExtensions: Set<String> = ["html", "htm", "xhtml", "xht", "shtml", "webarchive", "svg", "svgz", "mhtml", "mht"]

    public func route(_ url: URL) -> ExternalOpenRoute {
        if let linkScheme, let scheme = url.scheme, scheme.caseInsensitiveCompare(linkScheme) == .orderedSame {
            // The sign-in callback shares the scheme; it stays auth's, in
            // every form auth accepts.
            if isAuthCallback(url) { return .unsupported }
            return .deepLink(url)
        }
        switch url.scheme?.lowercased() {
        case "http", "https": return .browserTab(url)
        case "file": return routeFile(url.path)
        case "ssh": return ssh(url)
        case "x-man-page": return manPage(url)
        default: return .unsupported
        }
    }

    /// A web link from inside cmux (a feed item): only `http(s)` and this
    /// build's links, never a file or a terminal command, whatever the item
    /// carries.
    public func routeWebLink(_ url: URL) -> ExternalOpenRoute {
        switch route(url) {
        case .browserTab(let page) where page.scheme?.lowercased() != "file": .browserTab(page)
        case .deepLink(let link): .deepLink(link)
        default: .unsupported
        }
    }

    /// A web page continued from another device (Handoff,
    /// `NSUserActivityTypeBrowsingWeb`): a browser tab for its `http(s)` URL.
    /// Any other activity or URL is refused.
    public func route(continuing activityType: String, webpageURL: URL?) -> ExternalOpenRoute {
        guard activityType == NSUserActivityTypeBrowsingWeb, let url = webpageURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .unsupported }
        return .browserTab(url)
    }

    /// Finder service "New cmux Tab Here": a folder opens there; a file
    /// opens in its folder.
    public func newTabHere(_ path: String) -> ExternalOpenRoute {
        .terminal(cwd: isDirectory(path) ? path : (path as NSString).deletingLastPathComponent, command: nil)
    }

    func routeFile(_ path: String) -> ExternalOpenRoute {
        if isDirectory(path) { return .terminal(cwd: path, command: nil) }
        let ext = (path as NSString).pathExtension.lowercased()
        let folder = (path as NSString).deletingLastPathComponent
        if Self.pageExtensions.contains(ext) { return .browserTab(URL(fileURLWithPath: path)) }
        if let shell = Self.scriptShells[ext] {
            let quoted = ShellQuote.quote(path)
            return .terminal(cwd: folder, command: isExecutable(path) ? quoted : "\(shell) \(quoted)")
        }
        if ext.isEmpty, isExecutable(path) { return .terminal(cwd: folder, command: ShellQuote.quote(path)) }
        return .file(URL(fileURLWithPath: path))
    }

    /// `ssh://[user@]host[:port]`, as Terminal handles it. The host and
    /// user are restricted to the characters a host name or login can hold,
    /// and `--` ends ssh's options, so a crafted link cannot pass an option
    /// (`-oProxyCommand=...`) to ssh.
    func ssh(_ url: URL) -> ExternalOpenRoute {
        guard let host = url.host(percentEncoded: false), Self.isHostName(host) else { return .unsupported }
        var target = host.contains(":") ? "[\(host)]" : host
        if let user = url.user(percentEncoded: false) {
            guard Self.isLogin(user) else { return .unsupported }
            target = "\(user)@\(target)"
        }
        var command = "ssh"
        if let port = url.port {
            guard (1...65535).contains(port) else { return .unsupported }
            command += " -p \(port)"
        }
        return .terminal(cwd: nil, command: "\(command) -- \(ShellQuote.quote(target))")
    }

    /// `x-man-page://ls`, `x-man-page://1/ls`, `x-man-page:///ls`.
    func manPage(_ url: URL) -> ExternalOpenRoute {
        var parts = ([url.host(percentEncoded: false)] + url.pathComponents).compactMap { $0 }.filter { !$0.isEmpty && $0 != "/" }
        guard let topic = parts.popLast(), Self.isManToken(topic), parts.count <= 1 else { return .unsupported }
        if let section = parts.first {
            guard Self.isManToken(section) else { return .unsupported }
            return .terminal(cwd: nil, command: "man \(ShellQuote.quote(section)) \(ShellQuote.quote(topic))")
        }
        return .terminal(cwd: nil, command: "man \(ShellQuote.quote(topic))")
    }

    static func isHostName(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host.count <= 253
            && host.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || ".-_:%".unicodeScalars.contains($0) }
    }

    static func isLogin(_ user: String) -> Bool {
        !user.isEmpty && !user.hasPrefix("-") && user.count <= 64
            && user.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
    }

    static func isManToken(_ token: String) -> Bool {
        !token.hasPrefix("-") && token.count <= 128
            && token.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._+:-".unicodeScalars.contains($0) }
    }
}

/// POSIX shell single quoting: `it's` becomes `'it'\''s'`.
public nonisolated enum ShellQuote {
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
