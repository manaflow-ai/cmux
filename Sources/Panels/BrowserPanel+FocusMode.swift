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


// MARK: - Browser focus mode
extension BrowserPanel {
    private var canEnterBrowserFocusMode: Bool {
        shouldRenderWebView &&
            browserInteractiveModalHostWindow(for: webView) != nil &&
            !webView.isHiddenOrHasHiddenAncestor &&
            searchState == nil
    }

    var canToggleBrowserFocusMode: Bool {
        isBrowserFocusModeActive || canEnterBrowserFocusMode
    }

    @discardableResult
    func toggleBrowserFocusMode(reason: String, focusWebView: Bool = true) -> Bool {
        setBrowserFocusModeActive(
            !isBrowserFocusModeActive,
            reason: reason,
            focusWebView: focusWebView
        )
    }

    @discardableResult
    func setBrowserFocusModeActive(
        _ active: Bool,
        reason: String,
        focusWebView: Bool = true
    ) -> Bool {
        if !active {
            clearBrowserFocusMode(reason: reason)
            return true
        }

        guard canEnterBrowserFocusMode else {
#if DEBUG
            cmuxDebugLog(
                "browser.focusMode.activate.reject panel=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) render=\(shouldRenderWebView ? 1 : 0) " +
                "window=\(webView.window == nil ? 0 : 1) hidden=\(webView.isHiddenOrHasHiddenAncestor ? 1 : 0) " +
                "find=\(searchState == nil ? 0 : 1)"
            )
#endif
            return false
        }

        pendingAddressBarFocusRequestId = nil
        pendingAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
        isBrowserFocusModeActive = true
        clearBrowserFocusModeEscapeArms(reason: "\(reason).activate")
        preferredFocusIntent = .webView
        invalidateSearchFocusRequests(reason: "browserFocusModeActivate")

        let didFocus = focusWebView ? requestExplicitWebViewFocus() : true
        guard didFocus else {
            clearBrowserFocusMode(reason: "\(reason).focusFailed")
            return false
        }

#if DEBUG
        cmuxDebugLog("browser.focusMode.activate panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
        NotificationCenter.default.post(name: .browserFocusModeStateDidChange, object: id)
        return true
    }

    func clearBrowserFocusMode(reason: String) {
        let shouldNotify = isBrowserFocusModeActive || isBrowserFocusModeExitArmed
        guard isBrowserFocusModeActive ||
            isBrowserFocusModeExitArmed ||
            browserFocusModeExitArmedAt != nil ||
            lastBrowserFocusModePlainEscapeEventFingerprint != nil
        else { return }
        browserFocusModeExitArmedAt = nil
        lastBrowserFocusModePlainEscapeEventFingerprint = nil
        isBrowserFocusModeExitArmed = false
        isBrowserFocusModeActive = false
#if DEBUG
        cmuxDebugLog("browser.focusMode.clear panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
        if shouldNotify {
            NotificationCenter.default.post(name: .browserFocusModeStateDidChange, object: id)
        }
    }

    private func clearBrowserFocusModeEscapeArms(reason: String) {
        clearBrowserFocusModeExitArm(reason: reason)
        lastBrowserFocusModePlainEscapeEventFingerprint = nil
    }

    private func clearBrowserFocusModeExitArm(reason: String) {
        guard isBrowserFocusModeExitArmed || browserFocusModeExitArmedAt != nil else { return }
        browserFocusModeExitArmedAt = nil
        isBrowserFocusModeExitArmed = false
#if DEBUG
        cmuxDebugLog("browser.focusMode.escape.disarm panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
    }

    private func browserFocusModeEscapeArmIsFresh(for event: NSEvent) -> Bool {
        guard let startedAt = browserFocusModeExitArmedAt else { return false }
        guard startedAt > 0, event.timestamp > 0 else { return true }
        return max(0, event.timestamp - startedAt) <= Self.browserFocusModeEscapeSequenceInterval
    }

    func handleBrowserFocusModeKeyEvent(_ event: NSEvent, reason: String) -> BrowserFocusModeKeyDecision {
        guard canEnterBrowserFocusMode else {
            clearBrowserFocusMode(reason: "\(reason).ineligible")
            return .inactive
        }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let isPlainEscape = flags.isEmpty && event.keyCode == 53
        guard isPlainEscape else {
            lastBrowserFocusModePlainEscapeEventFingerprint = nil
            clearBrowserFocusModeEscapeArms(reason: "\(reason).nonEscape")
            return isBrowserFocusModeActive ? .forwardToWebView : .inactive
        }

        guard isBrowserFocusModeActive else {
            lastBrowserFocusModePlainEscapeEventFingerprint = nil
            clearBrowserFocusModeEscapeArms(reason: "\(reason).inactiveEscape")
            return .inactive
        }

        guard !event.isARepeat else {
#if DEBUG
            cmuxDebugLog("browser.focusMode.escape.repeat panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
            return .consume
        }

        let eventFingerprint = BrowserFocusModePlainEscapeEventFingerprint(event)
        if lastBrowserFocusModePlainEscapeEventFingerprint == eventFingerprint {
#if DEBUG
            cmuxDebugLog("browser.focusMode.escape.duplicate panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
            return .consume
        }
        lastBrowserFocusModePlainEscapeEventFingerprint = eventFingerprint

        if isBrowserFocusModeExitArmed {
            if browserFocusModeEscapeArmIsFresh(for: event) {
                clearBrowserFocusMode(reason: "\(reason).escapeExit")
                return .consume
            }

            browserFocusModeExitArmedAt = event.timestamp
#if DEBUG
            cmuxDebugLog("browser.focusMode.escape.rearm panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
            return .forwardToWebView
        }

        isBrowserFocusModeExitArmed = true
        browserFocusModeExitArmedAt = event.timestamp
#if DEBUG
        cmuxDebugLog("browser.focusMode.escape.arm panel=\(id.uuidString.prefix(5)) reason=\(reason)")
#endif
        return .forwardToWebView
    }

}
