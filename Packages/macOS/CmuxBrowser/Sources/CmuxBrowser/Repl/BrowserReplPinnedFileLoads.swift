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
/// has not yet answered for, one per web view: a navigation delegate asks
/// ``admitsResponse(_:isForMainFrame:governed:in:)`` before it lets a main
/// frame's response commit.
///
/// The browser also loads a file itself, without the driver: a history
/// item (back, forward), a reload, a restored page, a link. Before
/// macOS 27 such a load reads through a link swapped in since the page
/// first loaded, so the delegate pins every main-frame navigation of a
/// governed tab to a file when it decides it
/// (``pinNavigation(to:roots:in:)``), and refuses a governed file response
/// that no pin covers.
@MainActor
public final class BrowserReplPinnedFileLoads {
    public static let shared = BrowserReplPinnedFileLoads()

    private struct Entry {
        weak var webView: WKWebView?
        let pin: BrowserReplPinnedFileLoad
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    init() {}

    /// Notes that `webView` starts a pinned load: its main-frame response
    /// for the pinned file is judged by `pin`.
    func expect(_ pin: BrowserReplPinnedFileLoad, in webView: WKWebView) {
        entries = entries.filter { $0.value.webView != nil }
        entries[ObjectIdentifier(webView)] = Entry(webView: webView, pin: pin)
    }

    /// Checks a main-frame navigation of `webView` to the file `url` as the
    /// browser decides it (it opens the file only after), whoever started
    /// it, and pins it: its response then commits only while the file is
    /// still where this check found it. Replaces the web view's earlier pin.
    /// - Throws: `blocked` when the file is outside `roots`, a link lies
    ///   below them, or a root was moved or replaced
    ///   (``BrowserReplFileSandbox/withPinnedFileAccess(_:roots:in:_:)``).
    public func pinNavigation(to url: URL, roots: [BrowserReplFileRoot], in webView: WKWebView) throws {
        try BrowserReplFileSandbox.pinnedFileAccess(url.absoluteString, roots: roots) { pin in
            expect(pin, in: webView)
        }
    }

    /// Whether `webView` may commit `response`. A main-frame response for
    /// the file the web view's pin names ends that pin and is admitted only
    /// as ``BrowserReplPinnedFileLoad/admitsResponse(_:)`` says. A main-frame
    /// file response no pin covers is refused when `governed` (a browser
    /// REPL session governs the tab's loads of that file) or when it lies
    /// inside the pinned root: such a load was never checked, fail closed.
    /// Any other response (a non-file one, a child frame's, a file in a
    /// tab no session governs) is not this check's to refuse. A refused
    /// response leaves the pin waiting: a late response of a navigation
    /// the pinned one replaced must not let the pinned file pass unjudged.
    public func admitsResponse(_ response: URLResponse, isForMainFrame: Bool, governed: Bool, in webView: WKWebView) -> Bool {
        guard isForMainFrame, let url = response.url, url.isFileURL else { return true }
        let key = ObjectIdentifier(webView)
        let path = BrowserReplFileSandbox.lexicallyNormalized(url.path(percentEncoded: false))
        let entry = entries[key].flatMap { $0.webView === webView ? $0 : nil }
        if let entry, entry.pin.path == path {
            entries[key] = nil
            return entry.pin.admitsResponse(url)
        }
        if governed { return false }
        if let entry, BrowserReplFileSandbox.isLexicallyInside(path, roots: [entry.pin.root.path]) { return false }
        return true
    }
}
