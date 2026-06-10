import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit
import Network
import CFNetwork
import SQLite3
import CryptoKit
import Darwin
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif


// MARK: - Session snapshot & restored history
extension BrowserPanel {
    func sessionNavigationHistorySnapshot() -> (
        backHistoryURLStrings: [String],
        forwardHistoryURLStrings: [String]
    ) {
        realignRestoredSessionHistoryToLiveCurrentIfPossible()

        let nativeBack = webView.backForwardList.backList.compactMap {
            Self.serializableSessionHistoryURLString($0.url)
        }
        let nativeForward = webView.backForwardList.forwardList.compactMap {
            Self.serializableSessionHistoryURLString($0.url)
        }

        if usesRestoredSessionHistory {
            let back = restoredBackHistoryStack.compactMap { Self.serializableSessionHistoryURLString($0) }
            // `restoredForwardHistoryStack` stores nearest-forward entries at the end.
            let restoredForward = restoredForwardHistoryStack.reversed().compactMap {
                Self.serializableSessionHistoryURLString($0)
            }

            if isLiveSessionHistoryAlignedWithRestoredCurrent {
                return (
                    back,
                    restoredForward.isEmpty ? nativeForward : restoredForward
                )
            }

            return (back + nativeBack, nativeForward)
        }

        return (nativeBack, nativeForward)
    }

    private func resolvedLiveSessionHistoryURL() -> URL? {
        if let webViewURL = Self.remoteProxyDisplayURL(for: webView.url),
           Self.serializableSessionHistoryURLString(webViewURL) != nil {
            return webViewURL
        }
        if let currentURL,
           Self.serializableSessionHistoryURLString(currentURL) != nil {
            return currentURL
        }
        return nil
    }

    var isLiveSessionHistoryAlignedWithRestoredCurrent: Bool {
        let liveCurrent = Self.serializableSessionHistoryURLString(resolvedLiveSessionHistoryURL())
        let restoredCurrent = Self.serializableSessionHistoryURLString(restoredHistoryCurrentURL)
        guard let liveCurrent, let restoredCurrent else { return true }
        return liveCurrent == restoredCurrent
    }

    func realignRestoredSessionHistoryToLiveCurrentIfPossible() {
        guard usesRestoredSessionHistory else { return }
        guard let liveCurrent = resolvedLiveSessionHistoryURL(),
              let liveCurrentString = Self.serializableSessionHistoryURLString(liveCurrent) else {
            return
        }
        guard Self.serializableSessionHistoryURLString(restoredHistoryCurrentURL) != liveCurrentString else {
            return
        }

        let restoredBack = restoredBackHistoryStack.compactMap { Self.serializableSessionHistoryURLString($0) }
        let restoredForward = restoredForwardHistoryStack.reversed().compactMap {
            Self.serializableSessionHistoryURLString($0)
        }
        let restoredCurrent = Self.serializableSessionHistoryURLString(restoredHistoryCurrentURL)

        if let backIndex = restoredBack.lastIndex(of: liveCurrentString) {
            let newBack = Array(restoredBack[..<backIndex])
            var newForward = Array(restoredBack[(backIndex + 1)...])
            if let restoredCurrent {
                newForward.append(restoredCurrent)
            }
            newForward.append(contentsOf: restoredForward)

            restoredBackHistoryStack = Self.sanitizedSessionHistoryURLs(newBack)
            restoredForwardHistoryStack = Array(Self.sanitizedSessionHistoryURLs(newForward).reversed())
            restoredHistoryCurrentURL = liveCurrent
            refreshNavigationAvailability()
            return
        }

        if let forwardIndex = restoredForward.firstIndex(of: liveCurrentString) {
            var newBack = restoredBack
            if let restoredCurrent {
                newBack.append(restoredCurrent)
            }
            newBack.append(contentsOf: restoredForward[..<forwardIndex])
            let newForward = Array(restoredForward[(forwardIndex + 1)...])

            restoredBackHistoryStack = Self.sanitizedSessionHistoryURLs(newBack)
            restoredForwardHistoryStack = Array(Self.sanitizedSessionHistoryURLs(newForward).reversed())
            restoredHistoryCurrentURL = liveCurrent
            refreshNavigationAvailability()
            return
        }

        guard !restoredForwardHistoryStack.isEmpty else { return }
#if DEBUG
        cmuxDebugLog(
            "browser.history.restore.forward.clear panel=\(id.uuidString.prefix(5)) " +
            "current=\(liveCurrentString)"
        )
#endif
        restoredForwardHistoryStack.removeAll(keepingCapacity: false)
        refreshNavigationAvailability()
    }

    func restoreSessionNavigationHistory(
        backHistoryURLStrings: [String],
        forwardHistoryURLStrings: [String],
        currentURLString: String?
    ) {
        let restoredBack = Self.sanitizedSessionHistoryURLs(backHistoryURLStrings)
        let restoredForward = Self.sanitizedSessionHistoryURLs(forwardHistoryURLStrings)
        let restoredCurrent = Self.sanitizedSessionHistoryURL(currentURLString)
        guard !restoredBack.isEmpty || !restoredForward.isEmpty || restoredCurrent != nil else { return }

        usesRestoredSessionHistory = true
        restoredBackHistoryStack = restoredBack
        // Store nearest-forward entries at the end to make stack pop operations trivial.
        restoredForwardHistoryStack = Array(restoredForward.reversed())
        restoredHistoryCurrentURL = restoredCurrent
        refreshNavigationAvailability()
    }

    func restoreSessionSnapshot(_ snapshot: SessionBrowserPanelSnapshot) {
        // Diff viewer surfaces re-register their token from the on-disk manifest
        // and navigate via the app-owned custom scheme, so they restore even
        // though the local HTTP server that originally served them is gone.
        if let token = snapshot.diffViewerToken,
           let requestPath = snapshot.diffViewerRequestPath,
           CmuxDiffViewerURLSchemeHandler.shared.registerFromManifest(token: token),
           let diffURL = CmuxDiffViewerURLSchemeHandler.diffViewerURL(token: token, requestPath: requestPath) {
            hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(snapshot.shouldRenderWebView)
            setMuted(snapshot.isMuted)
            setOmnibarVisible(snapshot.omnibarVisible ?? false)
            currentURL = diffURL
            let shouldRenderRestoredWebView = snapshot.shouldRenderWebView && BrowserAvailabilitySettings.isEnabled()
            shouldRenderWebView = shouldRenderRestoredWebView
            guard shouldRenderRestoredWebView else {
                refreshNavigationAvailability()
                return
            }
            navigateWithoutInsecureHTTPPrompt(
                to: diffURL,
                recordTypedNavigation: false,
                preserveRestoredSessionHistory: false
            )
            return
        }

        let restoredURL = Self.sanitizedSessionHistoryURL(snapshot.urlString)
        let shouldRenderRestoredWebView = snapshot.shouldRenderWebView && BrowserAvailabilitySettings.isEnabled()
        hiddenWebViewDiscardManager.updateRestoredSessionRenderIntent(snapshot.shouldRenderWebView)
        setMuted(snapshot.isMuted)
        setOmnibarVisible(snapshot.omnibarVisible ?? true)

        restoreSessionNavigationHistory(
            backHistoryURLStrings: snapshot.backHistoryURLStrings ?? [],
            forwardHistoryURLStrings: snapshot.forwardHistoryURLStrings ?? [],
            currentURLString: snapshot.urlString
        )

        currentURL = restoredURL
        shouldRenderWebView = shouldRenderRestoredWebView

        guard shouldRenderRestoredWebView, let restoredURL else {
            refreshNavigationAvailability()
            return
        }

        navigateWithoutInsecureHTTPPrompt(
            to: restoredURL,
            recordTypedNavigation: false,
            preserveRestoredSessionHistory: true
        )
    }

    func shouldRenderWebViewForSessionSnapshot() -> Bool {
        // Diff viewer URLs are "temporary" so `preferredURLStringForSessionSnapshot()`
        // is nil, but they are restorable via their token, so honor their render
        // intent too (otherwise a restored diff surface never navigates).
        guard preferredURLStringForSessionSnapshot() != nil || diffViewerSessionComponents() != nil else {
            return false
        }
        return hiddenWebViewDiscardManager.restoredSessionShouldRenderWebView ?? shouldRenderWebView
    }

    func shouldPersistSessionSnapshot() -> Bool {
        // Diff viewer surfaces are otherwise treated as temporary. Persist them
        // only when they can actually be restored via the custom scheme (a
        // local-only, non-pending manifest); otherwise persisting would leave a
        // blank panel on restart with no URL to fall back to.
        if let components = diffViewerSessionComponents() {
            return CmuxDiffViewerURLSchemeHandler.shared.diffViewerRestorable(
                token: components.token,
                requestPath: components.requestPath
            )
        }
        guard !Self.isTemporarySessionHistoryURL(webView.url),
              !Self.isTemporarySessionHistoryURL(currentURL),
              !Self.isTemporarySessionHistoryURL(restoredHistoryCurrentURL) else {
            return false
        }
        return true
    }

    /// Whether this surface is transparent internal cmux UI, for the session
    /// snapshot (so it restores transparent rather than opaque).
    var sessionSnapshotTransparentBackground: Bool {
        usesTransparentBackground
    }

    /// The diff viewer `(token, requestPath)` for the live URL, if this surface
    /// is currently showing a diff viewer; used to persist + restore it.
    func diffViewerSessionComponents() -> (token: String, requestPath: String)? {
        CmuxDiffViewerURLSchemeHandler.diffViewerComponents(from: webView.url)
            ?? CmuxDiffViewerURLSchemeHandler.diffViewerComponents(from: currentURL)
    }

    func preferredURLStringForSessionSnapshot() -> String? {
        if let webViewURL = Self.remoteProxyDisplayURL(for: webView.url),
           let value = Self.serializableSessionHistoryURLString(webViewURL) {
            return value
        }
        if let currentURL,
           let value = Self.serializableSessionHistoryURLString(currentURL) {
            return value
        }
        return nil
    }

    func resolvedCurrentSessionHistoryURL() -> URL? {
        if let webViewURL = Self.remoteProxyDisplayURL(for: webView.url),
           Self.serializableSessionHistoryURLString(webViewURL) != nil {
            return webViewURL
        }
        if let currentURL,
           Self.serializableSessionHistoryURLString(currentURL) != nil {
            return currentURL
        }
        return restoredHistoryCurrentURL
    }

    func refreshNavigationAvailability() {
        let resolvedCanGoBack: Bool
        let resolvedCanGoForward: Bool
        if usesRestoredSessionHistory {
            resolvedCanGoBack = nativeCanGoBack || !restoredBackHistoryStack.isEmpty
            resolvedCanGoForward = nativeCanGoForward || !restoredForwardHistoryStack.isEmpty
        } else {
            resolvedCanGoBack = nativeCanGoBack
            resolvedCanGoForward = nativeCanGoForward
        }

        if canGoBack != resolvedCanGoBack {
            canGoBack = resolvedCanGoBack
        }
        if canGoForward != resolvedCanGoForward {
            canGoForward = resolvedCanGoForward
        }
    }

    func abandonRestoredSessionHistoryIfNeeded() {
        guard usesRestoredSessionHistory else { return }
        usesRestoredSessionHistory = false
        restoredBackHistoryStack.removeAll(keepingCapacity: false)
        restoredForwardHistoryStack.removeAll(keepingCapacity: false)
        restoredHistoryCurrentURL = nil
        refreshNavigationAvailability()
    }

    static func serializableSessionHistoryURLString(_ url: URL?) -> String? {
        guard let url else { return nil }
        guard !isTemporarySessionHistoryURL(url) else { return nil }
        let value = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "about:blank" else { return nil }
        return value
    }

    private static func sanitizedSessionHistoryURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "about:blank" else { return nil }
        guard let url = URL(string: trimmed),
              !isTemporarySessionHistoryURL(url) else {
            return nil
        }
        return url
    }

    private static func sanitizedSessionHistoryURLs(_ values: [String]) -> [URL] {
        values.compactMap { sanitizedSessionHistoryURL($0) }
    }

    private static func isTemporarySessionHistoryURL(_ url: URL?) -> Bool {
        browserIsTemporaryHistoryURL(url)
    }

}
