public import Foundation
import CmuxNextWindowRules
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
    /// Images opened with cmux or dropped on its Dock icon, or sent by the Send to cmux Chat
    /// service: they go into an agent chat's composer as an unsent draft (the focused chat, else a
    /// new one). `from`: the bundle id of the app they came from, when known.
    case attachImages([URL], from: String?)
    /// Any other file: the shared file opener (`file.open`), which shows
    /// Markdown in the Markdown page, text and code in the code editor page,
    /// and PDFs and media in a browser tab (images go to a chat: ``attachImages(_:from:)``).
    case file(URL)
    /// A link in this build's scheme (`cmux://tab/…`): the caller runs the
    /// `link.open` action with it, which only navigates.
    case deepLink(URL)
    /// A chat share link (`https://<host>/g/<id>#<secret>`, `/i/<id>`, or this build's
    /// `<scheme>://share?link=...#<secret>` from the guest page): the daemon checks it and answers the
    /// page to open in a browser tab, signed in as the person's cmux account. A link it refuses opens
    /// as a plain browser tab when it is a web address.
    case shareLink(URL)
    /// Not something cmux opens; the caller refuses it.
    case unsupported
}

/// Maps opened URLs and files to routes. Pure: no AppKit, no file writes;
/// `isDirectory` and `isExecutable` are injected for tests.
///
/// The rules are Rust's (cmux-window-rules `external_open`, op `onboarding_steps_external_open`,
/// with their cases): this reads the URL with Foundation (so the parts are the ones macOS read)
/// and looks at the file, Rust answers the route, and this builds it from the URL.
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

    /// The sign-in callback in any form auth accepts: `<scheme>://auth-callback`,
    /// `<scheme>:auth-callback` and `<scheme>:///auth-callback` (Rust `is_sign_in_callback`).
    public static func isSignInCallback(_ url: URL) -> Bool {
        WindowRules().call("onboarding_steps_sign_in_callback",
                           SignInCallback(host: url.host(percentEncoded: false), path: url.path),
                           as: SignInCallback.Reply.self)?.callback ?? false
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

    public func route(_ url: URL) -> ExternalOpenRoute {
        ask(url, mode: "open")
    }

    /// A web link from inside cmux (a feed item): only `http(s)` and this
    /// build's links, never a file or a terminal command, whatever the item
    /// carries.
    public func routeWebLink(_ url: URL) -> ExternalOpenRoute {
        ask(url, mode: "webLink")
    }

    /// A web page continued from another device (Handoff,
    /// `NSUserActivityTypeBrowsingWeb`): a browser tab for its `http(s)` URL,
    /// or a chat share page's own route. Any other activity or URL is refused.
    public func route(continuing activityType: String, webpageURL: URL?) -> ExternalOpenRoute {
        guard activityType == NSUserActivityTypeBrowsingWeb, let url = webpageURL else { return .unsupported }
        return ask(url, mode: "continuing")
    }

    /// Finder service "New cmux Tab Here": a folder opens there; a file
    /// opens in its folder.
    public func newTabHere(_ path: String) -> ExternalOpenRoute {
        .terminal(cwd: isDirectory(path) ? path : (path as NSString).deletingLastPathComponent, command: nil)
    }

    /// The route Rust answers for `url`, built from it; nil from an FFI pin without the op is
    /// refused.
    private func ask(_ url: URL, mode: String) -> ExternalOpenRoute {
        let request = RouteRequest(link: Link(url, authCallback: isAuthCallback(url)),
                                   file: url.scheme?.lowercased() == "file" ? file(url.path) : nil,
                                   linkScheme: linkScheme, mode: mode)
        guard let reply = WindowRules().call("onboarding_steps_external_open", request, as: RouteReply.self)
        else { return .unsupported }
        return reply.route(url)
    }

    /// What is at `path`: a folder, an executable, a picture.
    private func file(_ path: String) -> File {
        let ext = (path as NSString).pathExtension.lowercased()
        return File(path: path, folder: (path as NSString).deletingLastPathComponent, ext: ext,
                    isDirectory: isDirectory(path), isExecutable: isExecutable(path), isImage: Self.isImage(ext))
    }

    /// Whether a file of extension `ext` is a picture (PNG, JPEG, HEIC, TIFF, GIF and the rest).
    static func isImage(_ ext: String) -> Bool {
        !ext.isEmpty && UTType(filenameExtension: ext)?.conforms(to: .image) == true
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
    public var display: String { strings?.display ?? "" }

    /// The host as trust is keyed (``trustKey(_:)``).
    public var trustKey: String { Self.trustKey(host) }

    /// `host` without IPv6 brackets, lowercased (ASCII letters only), its IPv6 zone as spelled:
    /// the key the settings' trusted hosts compare by (Rust `trust_key`). An FFI pin without the
    /// op keys the host as written, so only the same spelling reads as trusted.
    public static func trustKey(_ host: String) -> String {
        WindowRules().call("onboarding_steps_trust_key", host, as: String.self) ?? host
    }

    /// The command typed into the new terminal, as Terminal runs the link.
    public var command: String { strings?.command ?? "" }

    /// The confirmation text, trust key and command, from Rust (`onboarding_steps_ssh_target`).
    private var strings: Strings? {
        WindowRules().call("onboarding_steps_ssh_target", Wire(self), as: Strings.self)
    }
}

/// POSIX shell single quoting: `it's` becomes `'it'\''s'`.
public nonisolated enum ShellQuote {
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
