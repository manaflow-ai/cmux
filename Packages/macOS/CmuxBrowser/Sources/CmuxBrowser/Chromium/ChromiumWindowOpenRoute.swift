/// `cef_window_open_disposition_t` (`include/internal/cef_types.h`).
public enum ChromiumWindowOpenDisposition: Int32, Equatable, Sendable {
    case unknown = 0
    case currentTab = 1
    case singletonTab = 2
    case newForegroundTab = 3
    case newBackgroundTab = 4
    case newPopup = 5
    case newWindow = 6
    case saveToDisk = 7
    case offTheRecord = 8
    case ignoreAction = 9
    case switchToTab = 10
    case newPictureInPicture = 11
    case newSplitView = 12

    public init(raw: Int) {
        self = ChromiumWindowOpenDisposition(rawValue: Int32(clamping: raw)) ?? .unknown
    }
}

/// Where a Chromium request to open a page lands in cmux.
///
/// Chromium never opens a window of its own (with its tab strip and
/// toolbar). A link with `target=_blank`, `window.open`, a Cmd-click or a
/// middle-click, "Open Link in New Tab" and an OAuth popup all arrive as one
/// request, and cmux routes it the way a WebKit panel routes the same request
/// (`browserNavigationShouldOpenInNewTab` / `browserNavigationShouldCreatePopup`):
///
/// - a scripted popup with window features (sign-in, payment) opens in cmux's
///   popup window, keeping `window.opener`;
/// - a new tab or window opens a Chromium browser tab next to its opener in
///   the same pane; a background tab does not take focus;
/// - a modified click mapped to the current tab loads in the opener, and one
///   mapped to a download downloads there;
/// - an incognito request opens nothing: cmux has no incognito window, and an
///   off-the-record page must never spill into a normal tab.
///
/// Reference: cmux Next `CmuxNextBrowser/CEF/CEFWindowPolicy.swift`,
/// `CEFWindowRequest.swift` and the `browser-link-tabs-chrome-order` release note.
public enum ChromiumWindowOpenRoute: Equatable, Sendable {
    /// cmux's popup window, sized from the request when it gave bounds.
    case popupWindow
    /// A new Chromium browser tab in the opener's pane.
    case newTab(focus: Bool)
    /// The opener loads the URL itself.
    case loadInOpener
    /// The opener downloads the URL.
    case downloadInOpener
    /// Nothing opens.
    case refuse

    /// The route for a request.
    ///
    /// - Parameters:
    ///   - disposition: What Chromium asked for.
    ///   - hasWindowFeatures: The request came with window features or bounds
    ///     (`window.open(url, name, "width=500")`).
    ///   - userGesture: A click or key caused the request, not a script.
    ///   - hasOpener: A page asked (0 means Chromium's own UI or an extension).
    ///   - hasURL: The request names a page.
    public static func route(
        disposition: ChromiumWindowOpenDisposition,
        hasWindowFeatures: Bool,
        userGesture: Bool,
        hasOpener: Bool,
        hasURL: Bool
    ) -> ChromiumWindowOpenRoute {
        switch disposition {
        case .offTheRecord:
            return .refuse
        case .ignoreAction:
            return .refuse
        case .newPopup:
            // A scripted popup keeps its opener. Chromium reports a
            // user-requested window with features as a popup too; Chrome
            // shows it as a popup window, so does cmux.
            return hasOpener ? .popupWindow : .newTab(focus: true)
        case .newWindow:
            // `window.open` without features from a script, or Shift-click.
            if hasWindowFeatures, hasOpener, !userGesture { return .popupWindow }
            return .newTab(focus: true)
        case .newBackgroundTab:
            return .newTab(focus: false)
        case .newForegroundTab, .singletonTab, .switchToTab, .newSplitView, .newPictureInPicture, .unknown:
            return .newTab(focus: true)
        case .currentTab:
            return hasOpener && hasURL ? .loadInOpener : .newTab(focus: true)
        case .saveToDisk:
            return hasOpener && hasURL ? .downloadInOpener : .refuse
        }
    }
}
