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
    /// An `ssh://` link: a terminal tab that runs `target.command`, after
    /// the App's confirmation (`ExternalLinkGate`): a page must not make
    /// cmux connect to a host it picks without the person's answer.
    case ssh(SSHLinkTarget)
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
        // Only `[user@]host[:port]`: no password, path, query or fragment, nothing a page could
        // hope cmux passes on, and every character as written ASCII (Foundation maps some
        // letters, the Kelvin sign, to ASCII ones before `host` is read).
        let text = url.absoluteString
        guard text.unicodeScalars.allSatisfy(\.isASCII), url.password(percentEncoded: true) == nil,
              url.query(percentEncoded: true) == nil, url.fragment(percentEncoded: true) == nil,
              ["", "/"].contains(url.path(percentEncoded: true)), Self.portIsWellFormed(url) else { return .unsupported }
        guard let host = url.host(percentEncoded: false), Self.isHostName(host) else { return .unsupported }
        var user: String?
        if let login = url.user(percentEncoded: false) {
            guard Self.isLogin(login) else { return .unsupported }
            user = login
        }
        if let port = url.port {
            guard (1...65535).contains(port) else { return .unsupported }
        }
        return .ssh(SSHLinkTarget(user: user, host: host, port: url.port))
    }

    /// A `:` after the host names a port URL could read (`host:` or `host:abc` is refused, never
    /// read as no port).
    static func portIsWellFormed(_ url: URL) -> Bool {
        guard url.port == nil, let rest = url.absoluteString.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false).dropFirst(2).first
        else { return true }
        var authority = Substring(rest)
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") { authority = authority[authority.index(after: close)...] }
        return !authority.contains(":")
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

    /// ASCII only: a look-alike letter (Cyrillic `а`, the Kelvin sign) would name another host
    /// than the one the confirmation seems to show.
    static func isHostName(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host.count <= 253
            && host.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-_:%".unicodeScalars.contains($0)) }
    }

    static func isLogin(_ user: String) -> Bool {
        !user.isEmpty && !user.hasPrefix("-") && user.count <= 64
            && user.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    static func isManToken(_ token: String) -> Bool {
        !token.hasPrefix("-") && token.count <= 128
            && token.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._+:-".unicodeScalars.contains($0) }
    }
}

/// Where an `ssh://[user@]host[:port]` link connects, as parsed: the host
/// and user are restricted to the characters a host name or login can hold
/// (``ExternalOpenRouter``), and `--` ends ssh's options, so a crafted link
/// cannot pass an option (`-oProxyCommand=...`), an identity file or a
/// command to ssh.
public nonisolated struct SSHLinkTarget: Equatable, Sendable {
    public let user: String?
    /// The host as the link names it, percent-decoded, without IPv6 brackets.
    public let host: String
    public let port: Int?

    public init(user: String?, host: String, port: Int?) {
        self.user = user
        self.host = host
        self.port = port
    }

    /// `user@host:port` as parsed (an IPv6 host in brackets), what the confirmation names.
    public var display: String {
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return (user.map { "\($0)@" } ?? "") + bracketed + (port.map { ":\($0)" } ?? "")
    }

    /// The host as trust is keyed (``trustKey(_:)``).
    public var trustKey: String { Self.trustKey(host) }

    /// `host` without IPv6 brackets, lowercased: OpenSSH lowercases the host before it reads
    /// its config, and DNS names compare without case. Nothing else is folded: `example.com.`
    /// or another spelling of an address is another string to ssh's `Host` patterns, so it asks.
    /// An IPv6 zone (`fe80::1%en0`) keeps its spelling: it names an interface, not a DNS label.
    public static func trustKey(_ host: String) -> String {
        var key = host.trimmingCharacters(in: .whitespaces)
        if key.hasPrefix("["), key.hasSuffix("]") { key = String(key.dropFirst().dropLast()) }
        let zone = key.firstIndex(of: "%").map { String(key[$0...]) } ?? ""
        let address = String(key.dropLast(zone.count))
        // ASCII letters only: Unicode lowercasing folds the Kelvin sign into `k`.
        return String(decoding: address.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self) + zone
    }

    /// The command typed into the new terminal, as Terminal runs the link.
    public var command: String {
        let bracketed = host.contains(":") ? "[\(host)]" : host
        let target = user.map { "\($0)@\(bracketed)" } ?? bracketed
        return "ssh" + (port.map { " -p \($0)" } ?? "") + " -- \(ShellQuote.quote(target))"
    }
}

/// POSIX shell single quoting: `it's` becomes `'it'\''s'`.
public nonisolated enum ShellQuote {
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
