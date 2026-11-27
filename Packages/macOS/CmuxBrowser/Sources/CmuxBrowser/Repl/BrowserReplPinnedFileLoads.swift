public import Foundation
public import WebKit

/// A browser load of a REPL session's file, as its check granted it
/// (``BrowserReplFileSandbox/withPinnedFileAccess(_:roots:in:_:)``): the
/// session root it may read, the file's path, how many REPL `fs.rename`s
/// had run then, and the directories (by identity) from the root to the
/// file's.
public struct BrowserReplPinnedFileLoad: Sendable, Equatable {
    let root: BrowserReplFileRoot
    /// The file's path, lexically normalized.
    let path: String
    let renameCount: UInt64
    let directories: Set<BrowserReplFileSandbox.DirectoryIdentity>

    /// The directory the page is granted read access to: the root.
    public var readAccess: URL { URL(fileURLWithPath: root.path, isDirectory: true) }

    /// Whether the load's response for the file `url` may commit.
    ///
    /// The browser opens a file before it asks about the response, and
    /// reads the bytes it opened. So the file it opened is inside the root
    /// when no REPL `fs.rename` since the check changed an entry of a
    /// directory on the file's path (only a rename can put a link at a
    /// path, and a rename back would leave the path as it was) and the path
    /// is still inside the root with no link below it, the root in place:
    /// whatever lay on the path when the browser opened it lies there now.
    public func admitsResponse(_ url: URL) -> Bool {
        BrowserReplFileSandbox.admits(url, pin: self)
    }
}

/// The pinned file loads (``BrowserReplPinnedFileLoad``) a tab started and
/// has not yet answered for, per web view: a navigation delegate asks
/// ``admitsResponse(_:isForMainFrame:governed:in:)`` before it lets a
/// frame's response commit.
///
/// The browser also loads a file itself, without the driver: a history
/// item (back, forward), a reload, a restored page, a link, a child frame.
/// Before macOS 27 such a load reads through a link swapped in since it was
/// checked, so the delegate pins every file navigation of a governed tab,
/// in any frame, when it decides it (``pinNavigation(to:isMainFrame:roots:in:)``),
/// and refuses a governed file response that no pin covers. A file
/// subresource (an image, a script, a style sheet) gets no such callback;
/// content rules match its URL only.
@MainActor
public final class BrowserReplPinnedFileLoads {
    public static let shared = BrowserReplPinnedFileLoads()

    /// Child-frame pins kept per web view; past it the oldest is dropped,
    /// and its response, if one still comes, is refused when governed.
    static let maximumFramePins = 64

    private struct Entry {
        weak var webView: WKWebView?
        var main: BrowserReplPinnedFileLoad?
        var frames: [BrowserReplPinnedFileLoad] = []
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    init() {}

    private func liveEntry(for webView: WKWebView) -> Entry? {
        entries[ObjectIdentifier(webView)].flatMap { $0.webView === webView ? $0 : nil }
    }

    /// Notes that `webView` starts a pinned load: its main-frame response
    /// for the pinned file is judged by `pin`, which replaces the web
    /// view's earlier main-frame pin; with `isMainFrame` false, a child
    /// frame's response for the file is, among the web view's other
    /// child-frame pins.
    func expect(_ pin: BrowserReplPinnedFileLoad, isMainFrame: Bool = true, in webView: WKWebView) {
        entries = entries.filter { $0.value.webView != nil }
        var entry = liveEntry(for: webView) ?? Entry(webView: webView)
        if isMainFrame {
            entry.main = pin
        } else {
            entry.frames.append(pin)
            if entry.frames.count > Self.maximumFramePins { entry.frames.removeFirst(entry.frames.count - Self.maximumFramePins) }
        }
        entries[ObjectIdentifier(webView)] = entry
    }

    /// Checks a navigation of a frame of `webView` (the main frame when
    /// `isMainFrame`) to the file `url` as the browser decides it (it opens
    /// the file only after), whoever started it, and pins it: its response
    /// then commits only while the file is still where this check found it.
    /// - Throws: `blocked` when the file is outside `roots`, a link lies
    ///   below them, or a root was moved or replaced
    ///   (``BrowserReplFileSandbox/withPinnedFileAccess(_:roots:in:_:)``).
    public func pinNavigation(to url: URL, isMainFrame: Bool, roots: [BrowserReplFileRoot], in webView: WKWebView) throws {
        try BrowserReplFileSandbox.pinnedFileAccess(url.absoluteString, roots: roots) { pin in
            expect(pin, isMainFrame: isMainFrame, in: webView)
        }
    }

    /// Whether `webView` may commit `response`. A main-frame response for
    /// the file the web view's main-frame pin names ends that pin, a child
    /// frame's for a file a child-frame pin names ends the pin that admits
    /// it, and each is admitted only as
    /// ``BrowserReplPinnedFileLoad/admitsResponse(_:)`` says. A file
    /// response no pin covers is refused when `governed` (a browser REPL
    /// session governs the tab's loads of that file) or when it lies inside
    /// a pinned root: such a load was never checked, fail closed. Any other
    /// response (a non-file one, a file in a tab no session governs) is not
    /// this check's to refuse. A refused main-frame response leaves the pin
    /// waiting: a late response of a navigation the pinned one replaced
    /// must not let the pinned file pass unjudged.
    public func admitsResponse(_ response: URLResponse, isForMainFrame: Bool, governed: Bool, in webView: WKWebView) -> Bool {
        guard let url = response.url, url.isFileURL else { return true }
        let key = ObjectIdentifier(webView)
        let path = BrowserReplFileSandbox.lexicallyNormalized(url.path(percentEncoded: false))
        var entry = liveEntry(for: webView)
        if isForMainFrame {
            if let pin = entry?.main, pin.path == path {
                entry?.main = nil
                entries[key] = entry
                return pin.admitsResponse(url)
            }
        } else if let frames = entry?.frames, frames.contains(where: { $0.path == path }) {
            guard let index = frames.firstIndex(where: { $0.path == path && $0.admitsResponse(url) }) else { return false }
            entry?.frames.remove(at: index)
            entries[key] = entry
            return true
        }
        if governed { return false }
        let pinnedRoots = ((entry?.main).map { [$0] } ?? []) + (entry?.frames ?? [])
        return !BrowserReplFileSandbox.isLexicallyInside(path, roots: pinnedRoots.map(\.root.path))
    }
}
