public import Foundation
public import AppKit
public import WebKit

/// The action a browser surface should take when WebKit asks it to create a new
/// web view for a navigation (`WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)`):
/// a `window.open()`, a `target=_blank`, or a user gesture that opens a link.
///
/// The classification is a stateless transform over the navigation's request,
/// opener URL, popup window-feature flag, and the user-gesture primitives. It
/// composes the external-scheme routing rule
/// (``BrowserExternalNavigationAction``) with the simple-user-gesture and
/// scripted-popup decisions on ``BrowserUserGestureNavigation``, never reading
/// live WebKit, window, or delegate state. The owning `WKUIDelegate` resolves
/// the decision with
/// ``resolve(request:openerURL:popupFeaturesWereSpecified:navigationType:modifierFlags:buttonNumber:hasRecentMiddleClickIntent:currentEventType:currentEventButtonNumber:)``
/// and performs the actual hand-off (external routing, current-tab load, popup
/// creation through the app-side `openPopup` closure that returns the live popup
/// `WKWebView`, or new-tab open), which stays app-side.
public enum BrowserCreateWebViewDecision: Sendable, Equatable {
    /// Hand `url` off to macOS for external routing (deeplink / native app)
    /// instead of creating a popup.
    case routeExternally(URL)

    /// Retarget the scripted `window.open` into the current tab because it is a
    /// simple keyboard/left-click activation without popup chrome
    /// (``BrowserUserGestureNavigation/opensSimpleUserGesturePopupInCurrentTab(requestMethod:requestURL:openerURL:popupFeaturesWereSpecified:)``).
    case openInCurrentTab(URLRequest)

    /// Create a real popup window for a scripted `.other` navigation that
    /// surfaced explicit popup window features
    /// (``BrowserUserGestureNavigation/createsPopup(popupFeaturesWereSpecified:)``).
    /// The app-side `openPopup` closure supplies the live popup `WKWebView`; if
    /// it is unavailable, the surface falls back to the new-tab behavior.
    case createPopup

    /// Open `request` in a new tab with no opener linkage: the fallback when the
    /// navigation is neither external, a current-tab retarget, nor a scripted
    /// popup.
    case openInNewTab(URLRequest)

    /// Classifies the action for a `createWebViewWith` navigation.
    ///
    /// The branch order is significant and matches the browser UI delegate:
    /// external routing first, then the simple-user-gesture current-tab
    /// retarget, then the scripted popup, then the new-tab fallback.
    ///
    /// - Parameters:
    ///   - request: The navigation action's request. Its `url` drives the
    ///     external check and the simple-user-gesture retarget; its `httpMethod`
    ///     gates the retarget; the full request is carried on the resulting
    ///     ``openInCurrentTab(_:)`` / ``openInNewTab(_:)`` so the delegate loads
    ///     it unchanged.
    ///   - openerURL: The opener web view's URL (`webView.url`), used to keep the
    ///     simple-user-gesture popup retarget same-origin.
    ///   - popupFeaturesWereSpecified: Whether WebKit surfaced explicit popup
    ///     window features (``BrowserPopupWindowFeatures/wereSpecified``). The
    ///     delegate computes this from `windowFeatures` and passes it in.
    ///   - navigationType: The action's `WKNavigationType`.
    ///   - modifierFlags: The active keyboard modifiers.
    ///   - buttonNumber: The mouse button WebKit reported.
    ///   - hasRecentMiddleClickIntent: Whether a local middle-click was just
    ///     observed (`CmuxWebView.hasRecentMiddleClickIntent(for:)`).
    ///   - currentEventType: The current AppKit event type
    ///     (`NSApp.currentEvent?.type`).
    ///   - currentEventButtonNumber: The current AppKit event's button number
    ///     (`NSApp.currentEvent?.buttonNumber`).
    /// - Returns: The action the delegate should perform.
    public static func resolve(
        request: URLRequest,
        openerURL: URL?,
        popupFeaturesWereSpecified: Bool,
        navigationType: WKNavigationType,
        modifierFlags: NSEvent.ModifierFlags,
        buttonNumber: Int,
        hasRecentMiddleClickIntent: Bool,
        currentEventType: NSEvent.EventType?,
        currentEventButtonNumber: Int?
    ) -> BrowserCreateWebViewDecision {
        if let url = request.url, BrowserExternalNavigationAction.shouldRoute(url) {
            return .routeExternally(url)
        }

        let gesture = BrowserUserGestureNavigation(
            navigationType: navigationType,
            modifierFlags: modifierFlags,
            buttonNumber: buttonNumber,
            hasRecentMiddleClickIntent: hasRecentMiddleClickIntent,
            currentEventType: currentEventType,
            currentEventButtonNumber: currentEventButtonNumber
        )

        let shouldOpenSimpleUserGesturePopupInCurrentTab = gesture.opensSimpleUserGesturePopupInCurrentTab(
            requestMethod: request.httpMethod,
            requestURL: request.url,
            openerURL: openerURL,
            popupFeaturesWereSpecified: popupFeaturesWereSpecified
        )

        if shouldOpenSimpleUserGesturePopupInCurrentTab {
            return .openInCurrentTab(request)
        }

        // Only treat scripted `.other` requests as popups when WebKit surfaced
        // explicit window features; bare `_blank` falls through to tabs.
        if gesture.createsPopup(popupFeaturesWereSpecified: popupFeaturesWereSpecified) {
            return .createPopup
        }

        // Fallback: open in new tab (no opener linkage).
        return .openInNewTab(request)
    }
}
