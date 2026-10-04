public import WebKit

/// Holds back the loads of new documents into a web view's child frames
/// while the driver's guarded input or capture is in flight.
///
/// The frame gate decides which frames are blocked from a frame tree read
/// before the input or capture, and holds those frames out of its reach
/// (inert for input, hidden for a capture). A frame the page creates
/// meanwhile, or an allowed frame it navigates to a blocked page, would show
/// a document no decision covered. Every such document starts with a
/// navigation WebKit asks the navigation delegate about, so while a hold is
/// on the web view the delegate answers child-frame navigations only once
/// the last hold comes off (``holdsBack(_:in:until:)``). A child frame then
/// shows nothing but the document it showed at the read, or a new frame's
/// initial empty document, which takes its parent's origin. Main-frame
/// navigations and new windows are not held: a new main document replaces
/// every frame, and a window the agent's click opens must still reach the
/// session while its input is handled.
@MainActor
public final class BrowserReplSubframeLoadHold {
    /// The holds the app's navigation delegate honors.
    public static let shared = BrowserReplSubframeLoadHold()

    private var holds: [ObjectIdentifier: Int] = [:]
    private var waiting: [ObjectIdentifier: [@MainActor () -> Void]] = [:]

    public init() {}

    /// One hold on one web view, taken by ``hold(_:)``.
    public struct Token: Sendable {
        fileprivate let webView: ObjectIdentifier
    }

    /// Holds back `webView`'s child-frame loads until ``release(_:)``.
    public func hold(_ webView: WKWebView) -> Token {
        let id = ObjectIdentifier(webView)
        holds[id, default: 0] += 1
        return Token(webView: id)
    }

    /// Takes a hold off. When it was the web view's last, the navigations
    /// held meanwhile go on, in the order WebKit asked about them.
    public func release(_ token: Token) {
        guard let count = holds[token.webView] else { return }
        if count > 1 {
            holds[token.webView] = count - 1
            return
        }
        holds[token.webView] = nil
        let resumed = waiting.removeValue(forKey: token.webView) ?? []
        for proceed in resumed { proceed() }
    }

    /// Runs `body` with `webView`'s child-frame loads held back.
    public func holding<T>(_ webView: WKWebView, _ body: () async throws -> T) async rethrows -> T {
        let token = hold(webView)
        defer { release(token) }
        return try await body()
    }

    /// Whether a navigation of `targetFrame` in `webView` waits: it targets
    /// a child frame while a hold is on the web view. Then `proceed` runs
    /// once the last hold comes off, and the caller must not decide the
    /// navigation now; otherwise `proceed` is dropped and the caller goes on.
    public func holdsBack(_ targetFrame: WKFrameInfo?, in webView: WKWebView, until proceed: @escaping @MainActor () -> Void) -> Bool {
        let id = ObjectIdentifier(webView)
        guard let targetFrame, !targetFrame.isMainFrame, holds[id] != nil else { return false }
        waiting[id, default: []].append(proceed)
        return true
    }

    /// How many navigations of `webView` wait for the holds to come off.
    func waitingCount(_ webView: WKWebView) -> Int {
        waiting[ObjectIdentifier(webView)]?.count ?? 0
    }
}
