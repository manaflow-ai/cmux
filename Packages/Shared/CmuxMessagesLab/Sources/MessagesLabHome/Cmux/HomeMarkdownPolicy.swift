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

    /// Thread safe (the sidebar preview may run off the main thread).
    static func install() {
        // Set inside the lock: a second caller returns only once the policy is in place.
        done.withLock { was in
            guard !was else { return }
            was = true
            // Only http, https and mailto become links, and one app form: a Chief
            // subagent's link (HomeAppLinks), which a click hands to the app.
            MarkdownLinkPolicy.extraSchemes = []
            MarkdownLinkPolicy.extraRule = HomeAppLinks.isSubagentLink
            MarkdownImages.provider = images
        }
    }
}

/// cmux: the app links Home renders. One form only: a Chief subagent's chat,
/// `cmux://chief/<home id>/session/<session id>` (optchat-chief `workspaces::subagent_link`;
/// home id 8 lowercase hex digits, session id 1 to 200 of `A-Za-z0-9-_.`; no user, port,
/// query or fragment). A click never goes to the system: the host's `onAppLink` runs it
/// (the app's `link.open`, for its own Chief's subagents only).
public struct HomeAppLinks {
    public init() {}
    public static let scheme = "cmux"

    /// Whether `url` is a Chief subagent link (Home makes it a link and a click opens it in the app).
    public static func isSubagentLink(_ url: URL) -> Bool {
        guard url.scheme == scheme, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
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
