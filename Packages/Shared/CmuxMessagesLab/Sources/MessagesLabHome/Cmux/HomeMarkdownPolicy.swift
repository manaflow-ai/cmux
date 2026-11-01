import AppKit
import ImageIO
import os

/// cmux: MessagesLab's Markdown security settings for Home, set once before
/// the first Markdown parse (MessagesLab caches parsed documents and
/// layouts, so a later change would not reach text already parsed). Every
/// Home entry point that can parse calls `install()`: the transcript view,
/// the pane controller and the sidebar preview.
enum HomeMarkdownPolicy {
    /// The attachment-only image provider (MarkdownImages holds it weakly).
    static let images = HomeMarkdownImages(directory: HomeMedia.directory)
    private static let done = OSAllocatedUnfairLock(initialState: false)
    /// True after `install()`; tests set it false to install again.
    static var installed: Bool {
        get { done.withLock { $0 } }
        set { done.withLock { $0 = newValue } }
    }

    /// MessagesLab f79bdbe: springs.json is this package's resource (Bundle.main has none), as
    /// MessagesLabLocalization.bundle; set before the first motion (install() here, the harness).
    static func installSprings() { Springs.bundle = .module }

    /// Thread safe (the sidebar preview may run off the main thread).
    static func install() {
        installSprings()  // every Home entry calls install() before its first view (ChatController.init too)
        // Set inside the lock: a second caller returns only once the policy is in place.
        done.withLock { was in
            guard !was else { return }
            was = true
            // Only http, https and mailto become links, and the app's own links
            // (URL.isCmuxAppLink: a workspace, pane, tab, chat or Chief subagent; URL.isHomePathLink:
            // an absolute path), which a click hands to the app, never to the system.
            MarkdownLinkPolicy.extraSchemes = []
            MarkdownLinkPolicy.extraRule = { $0.isCmuxAppLink || $0.isHomePathLink }
            MarkdownImages.provider = images
        }
    }
}

/// cmux: the app links Home renders. One form only: a Chief subagent's chat,
/// `cmux://chief/<home id>/session/<session id>` (optchat-chief `workspaces::subagent_link`;
/// home id 8 lowercase hex digits, session id 1 to 200 of `A-Za-z0-9-_.`; no user, port,
/// query or fragment). A click never goes to the system: the host's `onAppLink` runs it
/// (the app's `link.open`, for its own Chief's subagents only).
extension URL {
    /// Whether this URL is a Chief subagent link (Home makes it a link and a click opens it in the app).
    public var isChiefSubagentLink: Bool {
        guard scheme == "cmux", let c = URLComponents(url: self, resolvingAgainstBaseURL: false),
              c.user == nil, c.password == nil, c.port == nil, c.query == nil, c.fragment == nil,
              c.host == "chief" else { return false }
        let parts = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty, parts[2] == "session" else { return false }
        let home = parts[1].utf8, session = parts[3].utf8
        return home.count == 8 && home.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && (1...200).contains(session.count) && session.allSatisfy { b in
                (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) || b == 45 || b == 95 || b == 46
            }
    }
}

/// cmux: every app link Home renders and a click hands to the host's `onAppLink` (the app's
/// `link.open`), never to the system: a Chief subagent's link (``isChiefSubagentLink``), or
/// `cmux://workspace/ws_<32 hex>`, `pane/pane_<32 hex>`, `tab/tab_<32 hex>`, `settings/background`, `session/<id>`
/// (optional `#turn-<id>`) in the `cmux` scheme or a build's `cmux-…` one, with no user, port or
/// query other than the app's `machine=machine_…` hint. The app parses it again (DeepLink.parse).
extension URL {
    /// Whether this URL is a cmux app link (Home makes it a link and a click opens it in the app).
    public var isCmuxAppLink: Bool {
        if isChiefSubagentLink { return true }
        guard let scheme = scheme?.lowercased(), scheme == "cmux" || scheme.hasPrefix("cmux-"),
              let c = URLComponents(url: self, resolvingAgainstBaseURL: false),
              c.user == nil, c.password == nil, c.port == nil, let host = c.host?.lowercased() else { return false }
        if let items = c.queryItems, !items.allSatisfy({ $0.name == "machine" && ($0.value ?? "").hasPrefix("machine_") }) { return false }
        let parts = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].isEmpty else { return false }
        let id = String(parts[1])
        func token(_ text: String) -> Bool {
            (1...200).contains(text.utf8.count) && text.utf8.allSatisfy { b in
                (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) || b == 45 || b == 95 || b == 46
            }
        }
        func resource(_ prefix: String) -> Bool {
            guard id.hasPrefix(prefix), c.fragment == nil else { return false }
            let hex = id.dropFirst(prefix.count).utf8
            return hex.count == 32 && hex.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        switch host {
        case "workspace": return resource("ws_")
        case "pane": return resource("pane_")
        case "tab": return resource("tab_")
        // Chief's first-launch welcome: its background offer opens the background picker.
        case "settings": return id == "background" && c.fragment == nil
        // An agent-message fold's row (HomeAgentMessageRow.toggleLink): a click expands or collapses it.
        case "agent-messages":
            return c.fragment == nil && id.utf8.count == 16 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        case "session":
            guard token(id) else { return false }
            guard let fragment = c.fragment else { return true }
            return fragment.hasPrefix("turn-") && token(String(fragment.dropFirst(5)))
        default: return false
        }
    }
}

/// The only images Markdown may show in Home: attachment pictures that Home
/// already wrote (HomeMedia's folder, one file per content hash). A remote
/// URL, any other file and a missing file give no image (the text "[Image:
/// alt]" or a link); nothing is fetched. Called off the main thread.
final class HomeMarkdownImages: MarkdownImageProvider {
    private let directory: String
    private let lock = NSLock()
    private var pictures: [String: CGImage] = [:]

    init(directory: URL) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func markdownImage(source: String, alt: String) -> CGImage? {
        guard let url = URL(string: source), url.isFileURL else { return nil }
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard file.deletingLastPathComponent().path == directory else { return nil }
        lock.lock()
        if let hit = pictures[file.path] { lock.unlock(); return hit }
        lock.unlock()
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        lock.lock(); pictures[file.path] = image; lock.unlock()
        return image
    }
}

/// cmux: a path an agent wrote, as Home links it (`file:///Users/me/a.md`): an absolute local
/// path, no host other than `localhost`, no user, port, query or fragment. A click hands it to
/// the host's `onAppLink` (the app's file pages, or a terminal for a folder), never to the
/// system, so a path link never launches anything.
extension URL {
    /// Whether this URL is a path link Home renders (see the extension's discussion).
    public var isHomePathLink: Bool {
        guard scheme?.lowercased() == "file", let c = URLComponents(url: self, resolvingAgainstBaseURL: false),
              c.user == nil, c.password == nil, c.port == nil, c.query == nil, c.fragment == nil,
              (c.host ?? "").isEmpty || c.host == "localhost" else { return false }
        return path.hasPrefix("/")
    }
}
