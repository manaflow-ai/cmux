import AppKit
import CmuxBrowser
import CmuxSettings
import Foundation
import WebKit

/// Page state kept across a hidden-pane discard
/// (https://github.com/manaflow-ai/cmux/issues/15069).
///
/// A discard reads the dropped web view's WebKit session state, which holds
/// the back/forward list plus each entry's scroll position. The restore
/// assigns that state to the replacement web view instead of loading the URL
/// again, then refills unsaved form input once the page has loaded. The
/// snapshot taken when the pane was hidden covers the replacement until the
/// restored document paints.
extension BrowserPanel {
    /// What a discard reads from the web view it drops.
    struct DiscardedPageState {
        var interactionState: Data?
        var documentURL: URL?
        var coversNavigationHistory: Bool
    }

    /// Where a discarded pane comes back to, and the page state it keeps.
    struct DiscardRestoreTarget {
        var restoreURL: URL?
        var historyCurrentURLString: String?
        var pageState: DiscardedPageState
    }

    /// Resolves the restore for a web view about to be dropped. A web view
    /// whose process died restores the document it had committed when WebKit
    /// kept that document's session state, like a discarded Chrome tab: a
    /// load that had not committed is not what the user was looking at. It
    /// loads its recovery URL otherwise.
    func discardRestoreTarget(for webView: WKWebView) -> DiscardRestoreTarget {
        let pendingRecoveryURL = pendingWebContentRecoveryURL
        if pendingRecoveryURL != nil,
           let committedURL = webView.backForwardList.currentItem?.url {
            let committedDisplayURL = Self.remoteProxyDisplayURL(for: committedURL) ?? committedURL
            let committedState = pageStateForDiscard(
                from: webView,
                restoreURL: committedDisplayURL,
                pendingRecoveryURL: nil
            )
            if committedState.interactionState != nil {
                return DiscardRestoreTarget(
                    restoreURL: committedDisplayURL,
                    historyCurrentURLString: committedDisplayURL.absoluteString,
                    pageState: committedState
                )
            }
        }
        let restoreURL = pendingRecoveryURL
            ?? restorableDisplayURLForCurrentErrorPage(liveURL: webView.url)
        return DiscardRestoreTarget(
            restoreURL: restoreURL,
            historyCurrentURLString: pendingRecoveryURL?.absoluteString
                ?? preferredURLStringForOmnibar()
                ?? restoreURL?.absoluteString,
            pageState: pageStateForDiscard(
                from: webView,
                restoreURL: restoreURL,
                pendingRecoveryURL: pendingRecoveryURL
            )
        )
    }

    /// Reads the dropped web view's session state. Call before the web view is
    /// torn down and before restored URL history is reinstated, since both
    /// change what the state may be trusted to cover.
    func pageStateForDiscard(
        from webView: WKWebView,
        restoreURL: URL?,
        pendingRecoveryURL: URL?
    ) -> DiscardedPageState {
        pageRestoration.dismissOverlay()
        let documentURL = webView.backForwardList.currentItem?.url ?? webView.url
        var interactionState: Data?
        // Error pages and pending recoveries restore to a URL WebKit never
        // committed, so their session state would bring back the wrong page.
        if navigationDelegate?.activeErrorPageDisplayURL == nil,
           pendingRecoveryURL == nil,
           let documentURL,
           BrowserDiscardRestoreStrategy.canRestoreSessionState(for: documentURL),
           let restoreURL,
           BrowserFormStateSnapshot.isSameDocument(
               Self.remoteProxyDisplayURL(for: documentURL) ?? documentURL,
               restoreURL
           ) {
            interactionState = webView.interactionState as? Data
        }
        return DiscardedPageState(
            interactionState: interactionState,
            documentURL: documentURL,
            coversNavigationHistory: !usesRestoredSessionHistory
        )
    }

    /// Folds the discarded page's state into the pane's capture once the
    /// replacement web view points at the restore URL.
    func recordDiscardedPageState(_ state: DiscardedPageState) {
        pageRestoration.recordDiscard(
            interactionState: state.interactionState,
            documentURL: state.documentURL,
            anchorURL: restoredHistoryCurrentURL ?? currentURL,
            coversNavigationHistory: state.coversNavigationHistory
        )
    }

    /// Brings a discarded page back, from its session state when the capture
    /// still applies and by loading `url` otherwise.
    func performDiscardRestore(to url: URL, cachePolicy: URLRequest.CachePolicy, isExplicitReload: Bool) {
        if isExplicitReload {
            pageRestoration.dropCapture()
        }
        let conditions = BrowserDiscardRestoreStrategy.Conditions(
            isExplicitReload: isExplicitReload,
            usesRemoteWorkspaceProxy: usesRemoteWorkspaceProxy,
            usesCloudAccessRouting: retainsCloudResourceForDuplication || cloudBrowserMachineID != nil,
            hasRecoverableWebContentTermination: hasRecoverableWebContentTermination,
            requiresInsecureHTTPConsent: browserShouldBlockInsecureHTTPURL(url)
        )
        let strategy = BrowserDiscardRestoreStrategy.resolve(
            restoreURL: url,
            capture: pageRestoration.discardedCapture,
            conditions: conditions
        )
        if !restoreDiscardedPage(using: strategy, displayURL: url) {
            shouldRenderWebView = true
            // A remote pane queues the load until its proxy is back, and the
            // load's start clears any in-flight restore, so note the replay
            // once the load has started.
            navigateWithoutInsecureHTTPPrompt(
                to: url,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: true,
                cachePolicy: cachePolicy
            ) { [weak self] navigation in
                guard navigation != nil else { return }
                self?.pageRestoration.noteRestoreStarted(.urlReplay)
            }
        }
        if pageRestoration.discardedCapture != nil {
            showRestoreOverlay()
        }
    }

    /// Assigns captured session state, mirroring the bookkeeping a URL load
    /// does before it starts. WebKit replays the state as a back/forward
    /// navigation through the same policy checks as any other load, so a
    /// local file gets its trust grant back first.
    ///
    /// - Returns: Whether the state started a load. False leaves the caller
    ///   to load the URL instead.
    private func restoreDiscardedPage(using strategy: BrowserDiscardRestoreStrategy, displayURL url: URL) -> Bool {
        guard case .restoreInteractionState(let interactionState) = strategy,
              !url.isFileURL || BrowserURLAllowlistPolicy(defaults: .standard).allowsTrustedInternalURL(url) else {
            return false
        }
        let documentURL = pageRestoration.discardedCapture?.documentURL ?? url
        clearTrustedLocalFileDocumentIfNeeded(for: url)
        markTrustedInternalNavigationIfNeeded(for: url)
        webView.applyBrowserUserAgentPolicy(for: documentURL)
        hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(nil)
        navigationDelegate?.recordAttemptedRequest(URLRequest(url: documentURL), displayURL: url)
        refreshBackgroundAppearance()
        shouldRenderWebView = true
        noteDiscardedWebViewRestoreNavigationStarted()
        userStoppedLoadSinceWebViewReplacement = false
        webView.browserPortalMarkFirstSizedRevealNudgeIfNavigationStartsWithoutPresentation(
            reason: "navigationStart:\(url.scheme?.lowercased() ?? "none")"
        )
        webView.interactionState = interactionState
        // Assigning session state returns no navigation to track, so commit
        // bookkeeping falls back to matching the restore URL.
        pendingDiscardRestoreNavigation = nil
#if DEBUG
        cmuxDebugLog(
            "browser.discard.restore panel=\(id.uuidString.prefix(5)) method=interactionState " +
            "bytes=\(interactionState.count) started=\(webView.isLoading ? 1 : 0)"
        )
#endif
        // WebKit starts the back/forward load before the setter returns.
        // State it cannot decode, such as state saved by another WebKit
        // version, starts nothing.
        guard webView.isLoading else { return false }
        pageRestoration.noteRestoreStarted(.interactionState)
        return true
    }

    private func showRestoreOverlay() {
        pageRestoration.dismissOverlay()
        let overlay = BrowserPageSnapshotOverlayView(
            snapshot: pageRestoration.discardedCapture?.snapshot,
            restoringLabel: String(localized: "browser.discard.restoring", defaultValue: "Restoring…")
        )
        overlay.install(over: webView)
        pageRestoration.overlayView = overlay
    }

    /// Routes a main-frame document commit through the page-restoration state.
    func noteDocumentCommittedForPageRestoration(from webView: WKWebView) {
        guard shouldTreatCommitAsDiscardedRestoreCommit(from: webView) else {
            // The browser's error page keeps the capture for the next restore
            // attempt, and an about:blank placeholder is not the page itself.
            if navigationDelegate?.activeErrorPageDisplayURL != nil {
                pageRestoration.dismissOverlay()
            }
            return
        }
        let commit = pageRestoration.noteDocumentCommitted(
            isDiscardRestoreCommit: hiddenWebViewDiscardManager.isDiscardedForMemory
        )
        if commit?.method == .interactionState, commit?.coversNavigationHistory == true {
            // The assigned back/forward list is the pane's whole history now.
            abandonRestoredSessionHistoryIfNeeded()
        }
        if commit == nil {
            pageRestoration.dismissOverlay()
        }
        noteDiscardedWebViewRestoreNavigationCommitted()
    }

    /// Refills restored form input and removes the overlay once the restored
    /// document has loaded.
    func notePageRestorationLoadFinished(_ webView: WKWebView) {
        if navigationDelegate?.activeErrorPageDisplayURL == nil {
            applyPendingFormRestore(to: webView)
        }
        pageRestoration.dismissOverlay()
    }

    /// Drops the capture for a pane brought back without a restore.
    func notePageReactivatedWithoutRestore() {
        if pageRestoration.noteReactivatedWithoutRestore() {
            abandonRestoredSessionHistoryIfNeeded()
        }
        pageRestoration.dismissOverlay()
    }

    func tearDownPageRestoration(for webView: WKWebView) {
        tearDownFormStateMessageHandler(for: webView)
        pageRestoration.dismissOverlay()
    }

    /// Snapshots a pane that was just hidden, so a later discard can paint the
    /// page while it restores. Showing the pane again drops the snapshot.
    func noteHiddenSnapshotVisibility(_ visible: Bool, changed: Bool) {
        guard changed else { return }
        guard !visible else {
            pageRestoration.cancelHiddenSnapshot()
            return
        }
        guard hiddenWebViewDiscardManager.isPolicyEnabled,
              !hiddenWebViewDiscardManager.isDiscardedForMemory,
              shouldRenderWebView,
              navigationDelegate?.activeErrorPageDisplayURL == nil,
              BrowserDiscardRestoreStrategy.canRestoreSessionState(for: webView.url) else {
            return
        }
        let token = pageRestoration.beginHiddenSnapshot()
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let image,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let pointSize = image.size
            let source = BrowserSnapshotEncodingSource(image: cgImage)
            Task.detached(priority: .utility) {
                let encoded = source.jpegData()
                await MainActor.run {
                    guard let self, let encoded else { return }
                    self.pageRestoration.completeHiddenSnapshot(
                        token: token,
                        image: BrowserPageSnapshotImage(jpegData: encoded, pointSize: pointSize)
                    )
                    // The unloaded-page placeholder may already be showing without it.
                    if self.showsUnloadedPagePlaceholder {
                        self.objectWillChange.send()
                    }
                }
            }
        }
    }

    /// Whether the pane shows the unloaded-page placeholder: its page was
    /// unloaded to save memory and waits for the user to restore it.
    var showsUnloadedPagePlaceholder: Bool {
        webViewLifecycleState == .discarded && hiddenWebViewDiscardManager.waitsForManualRestore
    }

    /// What the pane asks the user to do before its page comes back, if anything.
    var pageRecoveryPrompt: BrowserPageRecoveryPrompt? {
        if shouldRenderWebView, hasRecoverableWebContentTermination {
            return .crashed
        }
        guard showsUnloadedPagePlaceholder else { return nil }
        return .unloaded(snapshot: pageRestoration.discardedCapture?.snapshot)
    }

    func performPageRecovery(_ prompt: BrowserPageRecoveryPrompt) {
        switch prompt {
        case .crashed:
            recoverTerminatedWebContent(reason: "overlayButton")
        case .unloaded:
            restoreUnloadedPage()
        }
    }

    /// Restores a page left unloaded for the user, with its history, scroll
    /// position and typed input.
    func restoreUnloadedPage() {
        restoreDiscardedWebViewIfNeeded(reason: "manual_restore")
    }

    /// Refreshes the placeholder after the automatic restore setting or the
    /// keep-active pin changes, and restores a shown page that no longer
    /// waits for the user.
    func noteUnloadedPageRestorePolicyChanged() {
        guard hiddenWebViewDiscardManager.isDiscardedForMemory else { return }
        objectWillChange.send()
        if isWebViewVisibleInUI {
            restoreDiscardedWebViewIfNeeded(reason: "policy_changed", trigger: .paneShown)
        }
    }

    /// Session state to write to the session file, or nil when this pane's
    /// state must not persist: private profiles, remote and cloud routing,
    /// error pages, form submissions, restored URL history and oversized state.
    /// Live state is also dropped while its current entry is not the URL the
    /// snapshot saves, because a relaunch restores it for that URL.
    func persistableInteractionStateForSessionSnapshot() -> Data? {
        guard shouldPersistSessionSnapshot(),
              !usesRemoteWorkspaceProxy,
              !retainsCloudResourceForDuplication,
              cloudBrowserMachineID == nil,
              navigationDelegate?.activeErrorPageDisplayURL == nil else {
            return nil
        }
        if hiddenWebViewDiscardManager.isDiscardedForMemory {
            return pageRestoration.persistableDiscardedInteractionState()
        }
        let documentURL = webView.backForwardList.currentItem?.url ?? webView.url
        guard BrowserDiscardRestoreStrategy.canRestoreSessionState(for: documentURL),
              Self.serializableSessionHistoryURLString(documentURL) == preferredURLStringForSessionSnapshot() else {
            return nil
        }
        return BrowserPageStateCapture.persistableInteractionState(
            webView.interactionState as? Data,
            coversNavigationHistory: !usesRestoredSessionHistory,
            containsFormSubmission: pageRestoration.liveContainsFormSubmission
        )
    }

    /// Seeds the capture from session state saved by a previous launch, so the
    /// deferred first load restores it instead of replaying the URL.
    func seedPageRestoration(from snapshot: SessionBrowserPanelSnapshot, restoredURL: URL) {
        guard let interactionState = snapshot.interactionState,
              restoredURL.absoluteString == snapshot.urlString,
              BrowserDiscardRestoreStrategy.canRestoreSessionState(for: restoredURL) else {
            return
        }
        pageRestoration.seedFromSessionState(interactionState, documentURL: restoredURL, anchorURL: restoredURL)
    }
}

extension BrowserNavigationDelegate {
    /// WebKit rendering milestones: first visually non-empty layout, session
    /// restoration render-tree threshold and first meaningful paint.
    private static let restoredContentPaintedEvents: UInt = (1 << 1) | (1 << 3) | (1 << 8)

    /// Removes the restore overlay once the restored document paints. WebKit
    /// reports these milestones without opting in.
    @objc(_webView:renderingProgressDidChange:)
    func webView(_ webView: WKWebView, renderingProgressDidChange progressEvents: UInt) {
        guard progressEvents & Self.restoredContentPaintedEvents != 0,
              let owner, owner.webView === webView else { return }
        owner.pageRestoration.dismissOverlay()
    }

    /// Tells the pane's restoration state about an allowed request, in any
    /// frame. WebKit keeps a submitted request body in the entry's session
    /// state, so a request with one marks that state as holding a form
    /// submission.
    func recordAllowedNavigationRequest(_ navigationAction: WKNavigationAction) {
        let method = navigationAction.request.httpMethod?.uppercased() ?? "GET"
        owner?.pageRestoration.noteNavigationRequest(
            targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame,
            isFormSubmission: method != "GET" && method != "HEAD"
        )
    }
}

/// A snapshot bitmap handed to a background task for JPEG encoding.
/// `CGImage` is immutable, so reading it off the main actor is safe.
private struct BrowserSnapshotEncodingSource: @unchecked Sendable {
    let image: CGImage

    func jpegData() -> Data? {
        NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.6]
        )
    }
}
