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
extension WebKitTab: BrowserFreezeReporting {
    // crash-allow: a string selector traps only when sent unanswered; `suspendPage` and `resumeIfSuspended` check responds(to:) first.
    static let suspendSelector = NSSelectorFromString("_suspendPage:")
    // crash-allow: as above.
    static let resumeSelector = NSSelectorFromString("_resumePage:")

    private typealias Completion = @convention(block) (Bool) -> Void
    private typealias Send = @convention(c) (AnyObject, Selector, @escaping Completion) -> Void

    /// Suspends or resumes the page. The request leaves before this returns; WebKit applies it in order, so a
    /// call made after a thaw runs on a resumed page. False when nothing changed: the tab closed, this WebKit
    /// has no such call, the page has no running process (WebKit suspends and resumes only such a page), or it
    /// already was in that state.
    @discardableResult
    public func setFrozen(_ frozen: Bool) -> Bool {
        guard !isClosed, let view = webView as? WebKitWebView else { return false }
        guard frozen else { return view.pageSuspended && resumeIfSuspended() }
        // A process still launching has no id yet; WebKit would suspend that page too, so it stays awake.
        guard !view.pageSuspended, view.responds(to: Self.suspendSelector), hasContentProcess else { return false }
        view.pageSuspended = true
        send(Self.suspendSelector)
        return true
    }

    public var isFrozen: Bool { webView.cmuxIsSuspended }

    /// Resumes a suspended page before a call WebKit raises on there (a load, a back or forward step, a
    /// reload, a stop, a zoom, a mute, a download, a notification click's script): the person's or the
    /// engine's command then runs on a live page. True when the page runs now. False when its process ended
    /// while it was suspended: WebKit keeps such a page suspended for good, the call must be skipped, and
    /// hibernation replaces the page (``onFrozenPageChange``). A page that runs again tells the host (`.woke`), which
    /// may freeze it again later.
    @discardableResult
    package func resumeIfSuspended() -> Bool {
        guard let view = webView as? WebKitWebView, view.pageSuspended else { return true }
        guard hasContentProcess, view.responds(to: Self.resumeSelector) else { return false }
        view.pageSuspended = false
        send(Self.resumeSelector)
        onFrozenPageChange?(.woke)
        return true
    }

    /// A suspended page's process ended (`webContentProcessEnded`): it can never run again.
    func frozenPageEnded() {
        guard webView.cmuxIsSuspended else { return }
        onFrozenPageChange?(.lost)
    }

    private var hasContentProcess: Bool {
        if case .pids(let pids) = contentProcesses { return !pids.isEmpty }
        return false
    }

    private func send(_ selector: Selector) {
        let send = unsafeBitCast(webView.method(for: selector), to: Send.self)
        send(webView, selector) { _ in }
    }
}
