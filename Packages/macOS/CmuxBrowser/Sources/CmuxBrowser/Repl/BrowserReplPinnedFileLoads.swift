public import Foundation
public import WebKit

/// A browser load of a REPL session's file, as its check granted it
/// (``BrowserReplFileSandbox/withPinnedFileAccess(_:roots:in:_:)``): the
/// session root it may read, how many REPL `fs.rename`s had run then, and
/// the directories (by identity) from the root to the file's.
public struct BrowserReplPinnedFileLoad: Sendable, Equatable {
    let root: BrowserReplFileRoot
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
/// ``admitsResponse(_:isForMainFrame:in:)`` before it lets a main frame's
/// response commit.
@MainActor
public final class BrowserReplPinnedFileLoads {
    public static let shared = BrowserReplPinnedFileLoads()

    private struct Entry {
        weak var webView: WKWebView?
        let pin: BrowserReplPinnedFileLoad
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    init() {}

    /// Notes that `webView` starts a pinned load: its next main-frame
    /// response is judged by `pin`.
    func expect(_ pin: BrowserReplPinnedFileLoad, in webView: WKWebView) {
        entries = entries.filter { $0.value.webView != nil }
        entries[ObjectIdentifier(webView)] = Entry(webView: webView, pin: pin)
    }

    /// Whether `webView` may commit `response`. A main-frame response for
    /// a file inside the root of the web view's pinned load ends that load
    /// and is admitted only as ``BrowserReplPinnedFileLoad/admitsResponse(_:)``
    /// says. Any other response (another URL's, from a navigation the load
    /// replaced or that replaced it; a child frame's; one in a web view
    /// with no pinned load) is not this check's to refuse, and leaves the
    /// pinned load waiting: a response that arrives late for a navigation
    /// the load replaced must not let the load's own response pass unjudged.
    public func admitsResponse(_ response: URLResponse, isForMainFrame: Bool, in webView: WKWebView) -> Bool {
        let key = ObjectIdentifier(webView)
        guard isForMainFrame, let entry = entries[key], entry.webView === webView,
              let url = response.url, url.isFileURL,
              BrowserReplFileSandbox.isLexicallyInside(url.path(percentEncoded: false), roots: [entry.pin.root.path]) else {
            return true
        }
        entries[key] = nil
        return entry.pin.admitsResponse(url)
    }
}
