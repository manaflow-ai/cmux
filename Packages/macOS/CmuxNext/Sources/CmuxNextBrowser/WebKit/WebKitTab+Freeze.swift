import Foundation
import WebKit

/// A hidden WebKit page frozen like a Chromium one (`CEFTab+Freeze`): after `browser.freezeHiddenTabs`
/// seconds hidden, `BrowserHibernation` probes it (media, capture, edited forms) and suspends it through
/// `-[WKWebView _suspendPage:]`, which stops its timers, animations and rendering until `_resumePage:`.
///
/// Hidden alone, a WebKit page kept waking: on cmux20-bench at 099fec0899cd each of 6 hidden idle pages
/// (visibilityState hidden, the bench's 1 s clock page) woke its web content process ~11 times a second,
/// with ~22 messages a second into the app and the GPU process, where the same Chromium pages, frozen, woke
/// 0.2 times. Hiding the WKWebView (`isHidden`) changed nothing; WebKit's own hidden-page throttling still
/// runs the page.
extension WebKitTab: BrowserFreezing {
    // crash-allow: a string selector traps only when sent unanswered; `setFrozen` checks responds(to:) first.
    static let suspendSelector = NSSelectorFromString("_suspendPage:")
    // crash-allow: as above.
    static let resumeSelector = NSSelectorFromString("_resumePage:")

    private typealias Completion = @convention(block) (Bool) -> Void
    private typealias Send = @convention(c) (AnyObject, Selector, @escaping Completion) -> Void

    /// Suspends or resumes the page. The request leaves before this returns; WebKit applies it in order, so a
    /// call made after a thaw runs on a resumed page. False when this WebKit has no such call or the tab closed.
    @discardableResult
    public func setFrozen(_ frozen: Bool) -> Bool {
        let selector = frozen ? Self.suspendSelector : Self.resumeSelector
        guard !isClosed, webView.responds(to: selector) else { return false }
        let send = unsafeBitCast(webView.method(for: selector), to: Send.self)
        send(webView, selector) { _ in }
        return true
    }
}
