public import AppKit
public import Foundation
public import WebKit
import CmuxCore

/// Pure decision logic for routing browser link activations and scripted
/// `window.open()` calls between a new tab, a popup window, the current tab, or
/// an external app.
///
/// Every method maps WebKit/AppKit inputs (a `WKNavigationType`, the click's
/// modifier flags and button number, the current `NSEvent`, and request/opener
/// URLs) to a `Bool` routing decision. There is no UI, no WebKit object
/// mutation, and no reach into app state, so the policy is a `Sendable` value
/// type rather than a set of free functions.
///
/// The navigation and UI delegates (in the browser panel and the popup window
/// controller) hold a policy and forward to it. Popup retargeting stays
/// intentionally narrow: only the explicit cross-host alias groups in
/// ``simpleUserGesturePopupRetargetHostAliases`` are retargeted to the current
/// tab, so opener-dependent OAuth/postMessage flows keep working as popups.
public struct BrowserPopupNavigationPolicy: Sendable {
    /// Cross-host alias groups whose scripted same-gesture popups may be
    /// retargeted into the current tab.
    ///
    /// Explicit alias groups preserve known first-party search flows without
    /// guessing at the public suffix list for arbitrary hosted tenants, while
    /// same-host scripted popups stay on the popup path so opener-dependent
    /// browser flows keep working.
    public let simpleUserGesturePopupRetargetHostAliases: [Set<String>]

    /// The default alias groups: the Bilibili search host family.
    public static let defaultSimpleUserGesturePopupRetargetHostAliases: [Set<String>] = [
        [
            "bilibili.com",
            "search.bilibili.com",
            "www.bilibili.com",
        ],
    ]

    /// Creates a policy with the given cross-host alias groups, defaulting to
    /// ``defaultSimpleUserGesturePopupRetargetHostAliases``.
    public init(
        simpleUserGesturePopupRetargetHostAliases: [Set<String>] =
            BrowserPopupNavigationPolicy.defaultSimpleUserGesturePopupRetargetHostAliases
    ) {
        self.simpleUserGesturePopupRetargetHostAliases = simpleUserGesturePopupRetargetHostAliases
    }

    /// Returns whether a link activation should open in a new tab: command-click,
    /// middle-click (button 2, or button 4 recovered from a recent local
    /// middle-click intent), or a middle-click event WebKit surfaced without a
    /// button number.
    public func shouldOpenInNewTab(
        navigationType: WKNavigationType,
        modifierFlags: NSEvent.ModifierFlags,
        buttonNumber: Int,
        hasRecentMiddleClickIntent: Bool = false,
        currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type,
        currentEventButtonNumber: Int? = NSApp.currentEvent?.buttonNumber
    ) -> Bool {
        guard navigationType == .linkActivated || navigationType == .other else {
            return false
        }

        if modifierFlags.contains(.command) {
            return true
        }
        if buttonNumber == 2 {
            return true
        }
        // In some WebKit paths, middle-click arrives as buttonNumber=4.
        // Recover intent when we just observed a local middle-click.
        if buttonNumber == 4, hasRecentMiddleClickIntent {
            return true
        }

        // WebKit can omit buttonNumber for middle-click link activations.
        if let currentEventType,
           (currentEventType == .otherMouseDown || currentEventType == .otherMouseUp),
           currentEventButtonNumber == 2 {
            return true
        }
        return false
    }

    /// Returns whether a scripted `.other` navigation that requested explicit
    /// window features should become a popup window, rather than a user-driven
    /// new tab.
    public func shouldCreatePopup(
        navigationType: WKNavigationType,
        modifierFlags: NSEvent.ModifierFlags,
        buttonNumber: Int,
        popupFeaturesWereSpecified: Bool = false,
        hasRecentMiddleClickIntent: Bool = false,
        currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type,
        currentEventButtonNumber: Int? = NSApp.currentEvent?.buttonNumber
    ) -> Bool {
        let isUserNewTab = shouldOpenInNewTab(
            navigationType: navigationType,
            modifierFlags: modifierFlags,
            buttonNumber: buttonNumber,
            hasRecentMiddleClickIntent: hasRecentMiddleClickIntent,
            currentEventType: currentEventType,
            currentEventButtonNumber: currentEventButtonNumber
        )
        return navigationType == .other && popupFeaturesWereSpecified && !isUserNewTab
    }

    /// Returns whether a `targetFrame == nil` navigation should fall back to a
    /// new tab. Scripted popups (`navigationType == .other`) rely on
    /// `WKUIDelegate.createWebViewWith` returning a live web view so
    /// `window.opener`/`postMessage` remain intact across OAuth flows.
    public func shouldFallbackNilTargetToNewTab(
        navigationType: WKNavigationType
    ) -> Bool {
        navigationType != .other
    }

    /// Returns whether the current `NSEvent` is a simple direct user activation
    /// (a key press or a left-click), as opposed to a scripted or synthetic
    /// trigger.
    public func hasSimpleUserActivation(
        currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type
    ) -> Bool {
        switch currentEventType {
        case .keyDown, .keyUp, .leftMouseDown, .leftMouseUp:
            return true
        default:
            return false
        }
    }

    /// Returns whether any popup window-feature geometry/chrome value was
    /// specified.
    public func popupFeaturesWereSpecified(
        x: NSNumber?,
        y: NSNumber?,
        width: NSNumber?,
        height: NSNumber?,
        menuBarVisibility: NSNumber?,
        statusBarVisibility: NSNumber?,
        toolbarsVisibility: NSNumber?,
        allowsResizing: NSNumber?
    ) -> Bool {
        x != nil ||
            y != nil ||
            width != nil ||
            height != nil ||
            menuBarVisibility != nil ||
            statusBarVisibility != nil ||
            toolbarsVisibility != nil ||
            allowsResizing != nil
    }

    /// Returns whether the given `WKWindowFeatures` specified any popup
    /// geometry/chrome value.
    public func popupFeaturesWereSpecified(windowFeatures: WKWindowFeatures) -> Bool {
        popupFeaturesWereSpecified(
            x: windowFeatures.x,
            y: windowFeatures.y,
            width: windowFeatures.width,
            height: windowFeatures.height,
            menuBarVisibility: windowFeatures.menuBarVisibility,
            statusBarVisibility: windowFeatures.statusBarVisibility,
            toolbarsVisibility: windowFeatures.toolbarsVisibility,
            allowsResizing: windowFeatures.allowsResizing
        )
    }

    /// Returns whether a scripted `window.open()` triggered by a simple GET
    /// user gesture, without requested popup chrome, should open in the current
    /// tab instead of a popup.
    ///
    /// Some sites use `window.open()` for plain same-site searches triggered by
    /// a direct keyboard submit or left-click, without requesting popup chrome
    /// or opener-style geometry. Those route to a normal tab while
    /// cross-site/OAuth-style popups stay on the popup path.
    public func shouldOpenSimpleUserGesturePopupInCurrentTab(
        navigationType: WKNavigationType,
        requestMethod: String?,
        requestURL: URL?,
        openerURL: URL?,
        modifierFlags: NSEvent.ModifierFlags = [],
        buttonNumber: Int = 0,
        hasRecentMiddleClickIntent: Bool = false,
        currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type,
        currentEventButtonNumber: Int? = NSApp.currentEvent?.buttonNumber,
        popupFeaturesWereSpecified: Bool
    ) -> Bool {
        guard navigationType == .other else {
            return false
        }
        guard hasSimpleUserActivation(currentEventType: currentEventType) else {
            return false
        }
        guard !shouldOpenInNewTab(
            navigationType: navigationType,
            modifierFlags: modifierFlags,
            buttonNumber: buttonNumber,
            hasRecentMiddleClickIntent: hasRecentMiddleClickIntent,
            currentEventType: currentEventType,
            currentEventButtonNumber: currentEventButtonNumber
        ) else {
            return false
        }
        guard (requestMethod ?? "GET").uppercased() == "GET" else {
            return false
        }
        guard !popupFeaturesWereSpecified else {
            return false
        }
        return shouldRetargetSimpleUserGesturePopup(
            requestURL: requestURL,
            openerURL: openerURL
        )
    }

    /// Returns a query/fragment-stripped string for the URL, for debug logging.
    /// Returns `"nil"` when the URL is absent or unparseable.
    public func debugURL(_ url: URL?) -> String {
        guard let url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "nil"
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? "\(url.scheme ?? "unknown")://\(url.host ?? "")"
    }

    /// Returns the default port for `http`/`https`, used to compare request and
    /// opener URLs that omit an explicit port.
    private func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }

    /// Returns whether a scripted simple-gesture popup may be retargeted to the
    /// current tab: same scheme, same effective port, different hosts, and both
    /// hosts in one of the configured cross-host alias groups.
    private func shouldRetargetSimpleUserGesturePopup(
        requestURL: URL?,
        openerURL: URL?
    ) -> Bool {
        guard let requestURL,
              let openerURL,
              let requestScheme = requestURL.scheme?.lowercased(), !requestScheme.isEmpty,
              let openerScheme = openerURL.scheme?.lowercased(), !openerScheme.isEmpty,
              requestScheme == openerScheme,
              (requestURL.port ?? defaultPort(for: requestScheme))
                == (openerURL.port ?? defaultPort(for: openerScheme)),
              let requestHost = RemoteLoopbackProxyAlias.normalizeHost(requestURL.host ?? ""),
              let openerHost = RemoteLoopbackProxyAlias.normalizeHost(openerURL.host ?? "") else {
            return false
        }
        for aliases in simpleUserGesturePopupRetargetHostAliases {
            if requestHost != openerHost,
               aliases.contains(requestHost),
               aliases.contains(openerHost) {
                return true
            }
        }
        return false
    }
}
