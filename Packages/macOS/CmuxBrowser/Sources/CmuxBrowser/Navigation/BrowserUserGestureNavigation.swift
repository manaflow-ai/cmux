public import AppKit
public import Foundation
public import WebKit

/// The user-input gesture context for a browser `WKNavigationAction`, capturing
/// the navigation type plus the modifier/button/event primitives needed to
/// decide whether a navigation or scripted `window.open` should open in a new
/// tab, become a popup window, or retarget into the current tab.
///
/// The decisions are pure transforms over the captured gesture: they read the
/// navigation type, the mouse button, the keyboard modifiers, a recent
/// middle-click intent flag, and the current AppKit event, never any live
/// WebKit, window, or delegate state. The owning navigation/UI delegate captures
/// those primitives — resolving `currentEventType`/`currentEventButtonNumber`
/// from `NSApp.currentEvent` in its main-actor context — and applies the
/// resulting routing, which stays app-side.
public struct BrowserUserGestureNavigation: Sendable {
    /// The action's `WKNavigationType`.
    public let navigationType: WKNavigationType
    /// The keyboard modifiers active for the gesture.
    public let modifierFlags: NSEvent.ModifierFlags
    /// The mouse button reported by WebKit for the gesture.
    public let buttonNumber: Int
    /// Whether a local middle-click was just observed, used to recover intent
    /// when WebKit reports `buttonNumber == 4`.
    public let hasRecentMiddleClickIntent: Bool
    /// The current AppKit event type, used to recover middle-click intent and to
    /// classify simple user activations.
    public let currentEventType: NSEvent.EventType?
    /// The current AppKit event's button number.
    public let currentEventButtonNumber: Int?

    /// Captures a browser navigation gesture.
    ///
    /// - Parameters:
    ///   - navigationType: The action's `WKNavigationType`.
    ///   - modifierFlags: The active keyboard modifiers.
    ///   - buttonNumber: The mouse button WebKit reported.
    ///   - hasRecentMiddleClickIntent: Whether a local middle-click was just observed.
    ///   - currentEventType: The current AppKit event type. The owning delegate
    ///     passes `NSApp.currentEvent?.type` from its main-actor context.
    ///   - currentEventButtonNumber: The current AppKit event's button number.
    public init(
        navigationType: WKNavigationType,
        modifierFlags: NSEvent.ModifierFlags = [],
        buttonNumber: Int = 0,
        hasRecentMiddleClickIntent: Bool = false,
        currentEventType: NSEvent.EventType? = nil,
        currentEventButtonNumber: Int? = nil
    ) {
        self.navigationType = navigationType
        self.modifierFlags = modifierFlags
        self.buttonNumber = buttonNumber
        self.hasRecentMiddleClickIntent = hasRecentMiddleClickIntent
        self.currentEventType = currentEventType
        self.currentEventButtonNumber = currentEventButtonNumber
    }

    /// Whether a cmd-click, middle-click, or recovered middle-click gesture
    /// should force the navigation to open in a new tab.
    public var opensInNewTab: Bool {
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

    /// Whether a scripted `.other` navigation with explicit popup window features
    /// should open as a popup window rather than a user-driven new tab.
    public func createsPopup(popupFeaturesWereSpecified: Bool = false) -> Bool {
        let isUserNewTab = opensInNewTab
        return navigationType == .other && popupFeaturesWereSpecified && !isUserNewTab
    }

    /// Whether a scripted `window.open` triggered by a simple keyboard/left-click
    /// activation should retarget into the current tab instead of a popup window.
    ///
    /// Some sites use `window.open()` for plain same-site searches triggered by a
    /// direct keyboard submit or left-click, without requesting popup chrome or
    /// opener-style geometry. Those route to a normal tab while cross-site/OAuth-
    /// style popups stay on the popup path.
    public func opensSimpleUserGesturePopupInCurrentTab(
        requestMethod: String?,
        requestURL: URL?,
        openerURL: URL?,
        popupFeaturesWereSpecified: Bool
    ) -> Bool {
        guard navigationType == .other else {
            return false
        }
        guard hasSimpleUserActivation else {
            return false
        }
        guard !opensInNewTab else {
            return false
        }
        guard (requestMethod ?? "GET").uppercased() == "GET" else {
            return false
        }
        guard !popupFeaturesWereSpecified else {
            return false
        }
        return Self.shouldRetargetSimpleUserGesturePopup(
            requestURL: requestURL,
            openerURL: openerURL
        )
    }

    /// Whether the current AppKit event is a simple key or left-mouse activation.
    private var hasSimpleUserActivation: Bool {
        switch currentEventType {
        case .keyDown, .keyUp, .leftMouseDown, .leftMouseUp:
            return true
        default:
            return false
        }
    }

    // Keep popup retargeting intentionally narrow. Explicit cross-host alias groups
    // preserve known first-party search flows without guessing at the public suffix
    // list for arbitrary hosted tenants, while same-host scripted popups stay on
    // the popup path so opener-dependent browser flows keep working.
    private static let simpleUserGesturePopupRetargetHostAliases: [Set<String>] = [
        [
            "bilibili.com",
            "search.bilibili.com",
            "www.bilibili.com",
        ],
    ]

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }

    private static func shouldRetargetSimpleUserGesturePopup(
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
              let requestHost = BrowserInsecureHTTPSettings.normalizeHost(requestURL.host ?? ""),
              let openerHost = BrowserInsecureHTTPSettings.normalizeHost(openerURL.host ?? "") else {
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
