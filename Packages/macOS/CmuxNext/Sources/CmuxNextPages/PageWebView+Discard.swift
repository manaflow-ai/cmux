import AppKit
public import Foundation
import CmuxNextSettings
import QuartzCore
import WebKit

/// What a page keeps for its discard and what its shell shows while it comes back
/// (plans/cmux-next/chrome-parity/p13-webui.md 3.C, "Discarded"). The view itself is the shell: it
/// keeps the descriptor, the route and the router; only the document and its engine page go.
struct PageDiscardShell {
    /// The last frame the page showed, kept when it hid (p13-webui-088); nil when none was kept.
    /// The restore draws it until the new document paints.
    var snapshot: CGImage?
    /// The state the page saved when it hid (p13-webui-088, 64 KB or less); nil when it saved none.
    /// The restored document reads it before its first paint (`takePageRestore` in pageClient.ts).
    var state: JSONValue?
    /// The document ended and the shell holds no engine page.
    var isDiscarded = false
    /// The snapshot layer over the page, from the restore until the new document's first paint.
    var cover: CALayer?
    /// The document-start script that hands the restored document ``state``, until its first paint.
    var restoreScript: WKUserScript?
    /// A restore waits for the first paint (one waiter, however many discards come before it).
    var awaitsPaint = false
    /// The last restore's times on the uptime clock (`debug.page` `restore`); nil before the first.
    var lastRestore: PageRestoreTimes?
}

/// When a discarded page's restore ran and drew, on the host uptime clock (`systemUptime` seconds),
/// for `debug.page` and the bench's discarded-page rows.
public struct PageRestoreTimes: Equatable, Sendable {
    /// The restore ran (the show's turn).
    public var started: TimeInterval
    /// The snapshot layer went over the page in that turn; nil when no snapshot was kept.
    public var covered: TimeInterval?
    /// The restored document's first painted frame; nil until it paints.
    public var painted: TimeInterval?
}

@MainActor
extension PageWebView {
    /// The global the restore script sets before page code runs (`RESTORE_NAME` in pageClient.ts).
    nonisolated static let restoreGlobal = "__cmuxPageRestore"

    /// True from the page's discard until it shows again: no document, no engine page, no subscription.
    public var isDiscarded: Bool { discardShell.isDiscarded }

    /// True while the hide-time snapshot covers the page (the restore runs, the new document has not painted).
    var showsDiscardSnapshot: Bool { discardShell.cover != nil }

    /// True when the page's next frame is its discard snapshot: it shows it now, or it is discarded
    /// with one that its show draws in the key's turn. A pane shows such a page at once (no paint
    /// hold), as it does a page under its last picture.
    public var drawsDiscardSnapshot: Bool {
        showsDiscardSnapshot || (discardShell.isDiscarded && discardShell.snapshot != nil)
    }

    /// The last restore's times (`debug.page`); nil when the page was never restored.
    public var lastRestoreTimes: PageRestoreTimes? { discardShell.lastRestore }

    /// Keeps what the page's hide took for a later discard (p13-webui-088 calls it on hide, before a
    /// freeze): the last shown frame and the state the page saved. A later hide replaces both.
    ///
    /// - Parameters:
    ///   - snapshot: The last frame the page showed; nil when none could be taken.
    ///   - state: The state the page saved on `visibilitychange` (64 KB or less); nil for none.
    func keepForDiscard(snapshot: CGImage?, state: JSONValue?) {
        discardShell.snapshot = snapshot
        discardShell.state = state
    }

    // MARK: Discard

    /// Discards the hidden page, as Chrome's `WebContents::Discard` (content/public/browser/web_contents.h)
    /// drops a background tab's renderer and keeps its navigation entry: the document and the engine
    /// page end, and the shell keeps descriptor, route, the hide-time snapshot and state. It makes no
    /// call into the page (a frozen page could not answer one) and finishes in this turn: the
    /// router closes (its subscriptions and calls end with no envelope sent) and stays closed until
    /// the restore, so nothing the old document still posts (a queued message, its `pagehide`)
    /// reaches a provider; the Chromium page closes (the fork's in-place discard replaces the close
    /// in p13-webui-031), and the WebKit view leaves its document for an empty one with no delegate.
    ///
    /// - Returns: True when the page is discarded (again: nothing more happens); false when refused:
    ///   it shows, or it is the pool's parked spare, whose life the pool owns. A claimed pooled host
    ///   is a page like any other.
    @discardableResult
    func discardPage() -> Bool {
        if discardShell.isDiscarded { return true }
        guard !isParkedSpare, !isShownForDiscard else { return false }
        // First: from here the page loads nothing, so ending its document below reports no load.
        discardShell.isDiscarded = true
        popupHost?.dismiss()
        router.close()
        _ = claimState.end()
        endChromium()
        chromiumUserEventUptime = nil
        chromiumDragFile = nil
        scriptTarget.bridge = bridge
        endWebKitDocument()
        removeRestoreCover()
        loaded = false
        paintedUptime = nil
        resumeLoadWaiters()
        return true
    }

    /// Whether the page shows now: in a window with no hidden view above it.
    private var isShownForDiscard: Bool {
        // visibility-walk-allow: the discard guard reads the AppKit state both engines take their visibility from; one walk per discard
        window != nil && !isHiddenOrHasHiddenAncestor
    }

    /// Ends the WebKit document: the view loads an empty document with no navigation delegate, so the
    /// old page's unload and the empty document's commit, finish or crash never reach the host. A
    /// view that never loaded (Chromium showed the page) has nothing to end and starts no process.
    private func endWebKitDocument() {
        webView.isHidden = true
        webView.navigationDelegate = nil
        guard webView.url != nil else { return }
        webView.stopLoading()
        if let blank = URL(string: "about:blank") { webView.load(URLRequest(url: blank)) }
    }

    // MARK: Restore

    /// Brings a discarded page back in the turn of its show, before it is visible: the hide-time
    /// snapshot covers the view at once (no implicit animation), the document-start restore script
    /// hands the new document its saved state, and the engine page is made again in the same group
    /// (the WebKit view keeps its process group; a Chromium page comes from the same
    /// ``PageChromiumHosting``, in its pane window once p13-webui-063 lands) and loads ``route``.
    /// The snapshot and the script go at the new document's first paint. Does nothing on a page
    /// that is not discarded.
    func restoreDiscardedPage() {
        guard discardShell.isDiscarded else { return }
        discardShell.isDiscarded = false
        let now = ProcessInfo.processInfo.systemUptime
        coverWithSnapshot()
        discardShell.lastRestore = PageRestoreTimes(started: now, covered: showsDiscardSnapshot ? now : nil)
        installRestoreScript()
        // Open again for the new document, with no subscription of the old one.
        router.reset()
        loadState.set(loading: true, page: self)
        paintedUptime = nil
        if !discardShell.awaitsPaint {
            discardShell.awaitsPaint = true
            whenPainted { [weak self] in self?.finishRestore() }
        }
        // Before either engine starts: a Chromium page that fails reopens in this WebKit view.
        webView.navigationDelegate = self
        if engineDecision.engine == .cef, let chromiumHost {
            startChromium(hosting: chromiumHost)
            return
        }
        webView.isHidden = false
        traceOpenLoadStarted(.reload)
        webView.load(URLRequest(url: descriptor.url(route: route)))
    }

    /// The restored document painted: the snapshot and the restore script go, and with them the
    /// hide-time snapshot and state, which a shown page no longer needs (its next hide keeps new ones).
    private func finishRestore() {
        discardShell.awaitsPaint = false
        discardShell.lastRestore?.painted = paintedUptime
        removeRestoreCover()
        discardShell.snapshot = nil
        discardShell.state = nil
    }

    /// Draws the hide-time snapshot over the page. A layer this view adds, so it sets every implicit
    /// action to `NSNull`: it shows and goes in one frame (motion-DESIGN.md, layers a task adds).
    private func coverWithSnapshot() {
        guard let image = discardShell.snapshot, let host = layer else { return }
        let cover = discardShell.cover ?? CALayer()
        cover.actions = Self.coverActions
        cover.contents = image
        cover.contentsGravity = .resize
        cover.contentsScale = window?.backingScaleFactor ?? host.contentsScale
        cover.zPosition = 1
        cover.frame = bounds
        if cover.superlayer !== host { host.addSublayer(cover) }
        discardShell.cover = cover
    }

    /// Keeps the snapshot on the view's bounds (``layout()``).
    func layoutDiscardCover() {
        discardShell.cover?.frame = bounds
    }

    /// Adds the document-start script that sets ``restoreGlobal`` to `{wasDiscarded: true, state}`
    /// before page code runs. A Chromium page takes it with the other user scripts when it starts.
    private func installRestoreScript() {
        let controller = webView.configuration.userContentController
        if let old = discardShell.restoreScript { Self.remove(old, from: controller) }
        let payload = JSONValue.object(["wasDiscarded": .bool(true), "state": discardShell.state ?? .null])
        let script = WKUserScript(source: Self.restoreScript(payload, token: UUID().uuidString),
                                  injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        controller.addUserScript(script)
        discardShell.restoreScript = script
    }

    /// The script that hands `payload` to the first document of this restore only: a Chromium page
    /// keeps its new-document scripts for later documents (a reload after a crash), which must not
    /// read a discard's old state, so the tab's session storage marks `token` as used.
    ///
    /// The document also reads `document.wasDiscarded` as true, as a Chrome document does after a
    /// discard (third_party/blink/renderer/core/dom/document.h, `Document::wasDiscarded`).
    nonisolated static func restoreScript(_ payload: JSONValue, token: String) -> String {
        let key = JSONValue.string("cmux.page.restore." + token).compactText
        return """
        (() => {
        try { if (sessionStorage.getItem(\(key))) return; sessionStorage.setItem(\(key), "1"); } catch (_) {}
        window.\(restoreGlobal) = \(payload.compactText);
        try { Object.defineProperty(document, "wasDiscarded", { value: true, configurable: true }); } catch (_) {}
        })();
        """
    }

    /// Removes the snapshot layer and the restore script.
    private func removeRestoreCover() {
        discardShell.cover?.removeFromSuperlayer()
        discardShell.cover = nil
        if let script = discardShell.restoreScript {
            Self.remove(script, from: webView.configuration.userContentController)
            discardShell.restoreScript = nil
        }
    }

    /// `script` leaves `controller`; the others stay in their order (WebKit has no public single remove).
    private static func remove(_ script: WKUserScript, from controller: WKUserContentController) {
        let kept = controller.userScripts.filter { $0 !== script }
        guard kept.count != controller.userScripts.count else { return }
        controller.removeAllUserScripts()
        for item in kept { controller.addUserScript(item) }
    }

    /// No implicit animation of the snapshot layer: it appears, resizes and goes in one frame.
    private static var coverActions: [String: any CAAction] {
        ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(),
         "onOrderIn": NSNull(), "onOrderOut": NSNull(), "sublayers": NSNull()]
    }
}
