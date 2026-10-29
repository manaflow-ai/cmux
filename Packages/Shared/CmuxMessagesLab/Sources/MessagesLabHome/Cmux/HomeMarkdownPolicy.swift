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
/// `cmux://workspace/ws_<32 hex>`, `pane/pane_<32 hex>`, `tab/tab_<32 hex>`, `session/<id>`
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
/// alt]" or a link); nothing is fetched. Called off the main thread (the Markdown layout and
/// the row bitmaps), so it is Sendable: the folder is a constant and the decoded pictures sit
/// behind their lock.
///
/// The kept pictures are a byte-capped LRU, sized and trimmed by the host with the
/// transcript's other pixel caches (`MessagesLabTranscriptCaches`); a dropped picture decodes again
/// from its file at the next ask.
final class HomeMarkdownImages: MarkdownImageProvider, Sendable { // memory: consumer via MessagesLabMemoryConsumer (CmuxNextHome)
    /// The cap until the host sizes the pictures (`setBudget(bytes:)`).
    static let defaultBudget = 32 << 20
    private let directory: String
    private struct Entry: Sendable { var image: HomeShared<CGImage>; var bytes: Int; var tick: Int }
    private struct State: Sendable {
        var budget = HomeMarkdownImages.defaultBudget
        var map: [String: Entry] = [:]
        var bytes = 0
        var tick = 0
    }
    // Lock carve-out: a synchronous cache read from layout and drawing threads (MarkdownImageProvider is
    // a synchronous call); the decode runs outside the lock, an eviction is a sort of the kept pictures.
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(directory: URL) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The decoded pictures' bytes now.
    var bytes: Int { state.withLock { $0.bytes } }
    /// The pictures kept now.
    var count: Int { state.withLock { $0.map.count } }
    /// The most bytes kept.
    var budget: Int { state.withLock { $0.budget } }

    /// The host's cap; lowering it frees nothing now (the next store trims to it).
    func setBudget(bytes: Int) {
        state.withLock { $0.budget = max(0, bytes) }
    }

    /// Frees the least recently asked pictures until at most `fraction` of the bytes held now remain (0 frees
    /// all of them); the images are released off main. A row already drawn keeps its bitmap.
    func trim(toFraction fraction: Double) {
        let freed = state.withLock { s in Self.evict(&s, downTo: s.bytes.trimTarget(fraction)) }
        Reclaimer.release(bitmaps: freed)
    }

    func markdownImage(source: String, alt: String) -> CGImage? {
        guard let url = URL(string: source), url.isFileURL else { return nil }
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard file.deletingLastPathComponent().path == directory else { return nil }
        let path = file.path
        let hit = state.withLock { s -> HomeShared<CGImage>? in
            guard var entry = s.map[path] else { return nil }
            s.tick += 1
            entry.tick = s.tick
            s.map.updateValue(entry, forKey: path) // dictionary write
            return entry.image
        }
        if let hit { return hit.value }
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let shared = HomeShared(image)
        let bytes = image.bytesPerRow * image.height
        let (kept, freed) = state.withLock { s -> (HomeShared<CGImage>, [HomeShared<CGImage>]) in
            // Another thread decoded it meanwhile: every caller gets the one kept picture.
            if let other = s.map[path] { return (other.image, []) }
            guard bytes <= s.budget else { return (shared, []) }
            s.tick += 1
            s.map.updateValue(Entry(image: shared, bytes: bytes, tick: s.tick), forKey: path) // dictionary write
            s.bytes += bytes
            return (shared, s.bytes > s.budget ? Self.evict(&s, downTo: s.budget * 4 / 5) : [])
        }
        Reclaimer.release(bitmaps: freed)
        return kept.value
    }

    /// Unlinks the least recently asked pictures until at most `target` bytes remain; returns them to free.
    private static func evict(_ s: inout State, downTo target: Int) -> [HomeShared<CGImage>] {
        var freed: [HomeShared<CGImage>] = []
        guard s.bytes > target else { return freed }
        for (key, entry) in s.map.sorted(by: { $0.value.tick < $1.value.tick }) {
            if s.bytes <= target { break }
            s.map.removeValue(forKey: key)
            s.bytes -= entry.bytes
            freed.append(entry.image)
        }
        return freed
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
