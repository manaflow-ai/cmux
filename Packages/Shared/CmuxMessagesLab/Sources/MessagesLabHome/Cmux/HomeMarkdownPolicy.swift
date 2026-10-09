import AppKit
import ImageIO

/// cmux: MessagesLab's Markdown security settings for Home, set once before
/// the first Markdown parse (MessagesLab caches parsed documents and
/// layouts, so a later change would not reach text already parsed). Every
/// Home entry point that can parse calls `install()`: the transcript view,
/// the pane controller and the sidebar preview.
enum HomeMarkdownPolicy {
    /// The attachment-only image provider (MarkdownImages holds it weakly).
    static let images = HomeMarkdownImages(directory: HomeMedia.directory)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var done = false
    /// True after `install()`; tests set it false to install again.
    static var installed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return done }
        set { lock.lock(); done = newValue; lock.unlock() }
    }

    /// Thread safe (the sidebar preview may run off the main thread).
    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        // Only http, https and mailto become links: Home allows no extra scheme.
        MarkdownLinkPolicy.extraSchemes = []
        MarkdownImages.provider = images
    }
}

/// The only images Markdown may show in Home: attachment pictures that Home
/// already wrote (HomeMedia's folder, one file per content hash). A remote
/// URL, any other file and a missing file give no image (the text "[Image:
/// alt]" or a link); nothing is fetched. Called off the main thread.
final class HomeMarkdownImages: MarkdownImageProvider {
    private let directory: String
    private let lock = NSLock()
    private var cache: [String: CGImage] = [:]

    init(directory: URL) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func markdownImage(source: String, alt: String) -> CGImage? {
        guard let url = URL(string: source), url.isFileURL else { return nil }
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard file.deletingLastPathComponent().path == directory else { return nil }
        lock.lock()
        if let hit = cache[file.path] { lock.unlock(); return hit }
        lock.unlock()
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        lock.lock(); cache[file.path] = image; lock.unlock()
        return image
    }
}
