import AppKit
import Foundation

@MainActor
extension BrowserPanel: OmnibarHostingPanel {
    var omnibarDisplayURL: URL? { currentURL }

    var isContentBlankForOmnibar: Bool {
        preferredURLStringForOmnibar() == nil
    }

    var isContentNavigationInFlight: Bool { webView.isLoading }

    var omnibarHostWindow: NSWindow? { webView.window }

    func beginSuppressContentFocusForAddressBar() {
        beginSuppressWebViewFocusForAddressBar()
    }

    func endSuppressContentFocusForAddressBar() {
        endSuppressWebViewFocusForAddressBar()
    }

    func shouldSuppressContentFocus() -> Bool {
        shouldSuppressWebViewFocus()
    }

    func performAddressBarExitFocusHandoff(
        isCurrentOwner: @escaping @MainActor () -> Bool,
        onComplete: @escaping @MainActor (Bool) -> Void
    ) {
        endSuppressWebViewFocusForAddressBar()
        DispatchQueue.main.async {
            guard let window = self.webView.window,
                  !self.webView.isHiddenOrHasHiddenAncestor else {
                onComplete(false)
                return
            }
            guard self.shouldApplyAddressBarExitFocusHandoff(
                in: window,
                isCurrentOwner: isCurrentOwner
            ) else {
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.addressBar.exit.handoff panel=\(self.id.uuidString.prefix(5)) " +
                    "result=skip_not_focused"
                )
#endif
                onComplete(false)
                return
            }

            self.clearWebViewFocusSuppression()
            let focusedWebView = window.makeFirstResponder(self.webView)
            if focusedWebView {
                self.noteWebViewFocused()
            }
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.exit.handoff panel=\(self.id.uuidString.prefix(5)) " +
                "focusedWebView=\(focusedWebView ? 1 : 0)"
            )
#endif
            self.restoreAddressBarPageFocusIfNeeded { restored in
                guard self.shouldApplyAddressBarExitFocusHandoff(
                    in: window,
                    isCurrentOwner: isCurrentOwner
                ) else {
#if DEBUG
                    cmuxDebugLog(
                        "browser.focus.addressBar.exit.handoff panel=\(self.id.uuidString.prefix(5)) " +
                        "result=skip_stale_restore restored=\(restored ? 1 : 0)"
                    )
#endif
                    onComplete(false)
                    return
                }
                var hasWebViewResponder = Self.responderChainContains(
                    window.firstResponder,
                    target: self.webView
                )
                if !hasWebViewResponder {
                    let fallbackFocusedWebView = window.makeFirstResponder(self.webView)
                    hasWebViewResponder = fallbackFocusedWebView
#if DEBUG
                    cmuxDebugLog(
                        "browser.focus.addressBar.exit.handoff panel=\(self.id.uuidString.prefix(5)) " +
                        "fallbackFocusedWebView=\(fallbackFocusedWebView ? 1 : 0) " +
                        "restored=\(restored ? 1 : 0)"
                    )
#endif
                }
                if hasWebViewResponder {
                    self.noteWebViewFocused()
                }
                onComplete(hasWebViewResponder)
            }
        }
    }

    private func shouldApplyAddressBarExitFocusHandoff(
        in window: NSWindow,
        isCurrentOwner: @MainActor () -> Bool
    ) -> Bool {
        webView.window === window && searchState == nil && isCurrentOwner()
    }

    private static func responderChainContains(
        _ start: NSResponder?,
        target: NSResponder
    ) -> Bool {
        var current = start
        var hops = 0
        while let responder = current, hops < 64 {
            if responder === target { return true }
            current = responder.nextResponder
            hops += 1
        }
        return false
    }
}
