import CoreGraphics
import Foundation

/// Chromium never opens a window of its own (with its tab strip, toolbar
/// and menus). Every request that would open one arrives here: a link that
/// opens a new window or popup, `window.open`, a link from a `chrome://`
/// page, `chrome.windows.create`, `chrome.tabs.create` without a window,
/// "Open Link in New Window/Incognito Window", Chrome commands (New Window,
/// Task Manager), a Browser Chromium created on its own. The runtime turns
/// each into a cmux tab through one decision (`CEFWindowPolicy.decide`).
nonisolated struct CEFWindowRequest: Equatable, Sendable {
    /// What Chromium wanted to create (`cmux_window_request_kind_t` of the
    /// fork, `cef_cmux.h`).
    enum Kind: Int32, Equatable, Sendable {
        /// A new tab with no window to hold it.
        case tab = 0
        /// A normal window (`NEW_WINDOW`, `chrome.windows.create`, Cmd-N).
        case window = 1
        /// A popup window with window features (`window.open` with a size,
        /// OAuth and payment popups, `chrome.windows.create({type: 'popup'})`).
        case popup = 2
        /// An incognito window or tab. cmux has no Chromium incognito mode.
        case offTheRecord = 3
        /// An app or PWA window.
        case app = 4
    }

    var kind: Kind
    /// `cef_window_open_disposition_t` as Chromium asked.
    var disposition: CEFDisposition
    /// The tab that asked, or 0 (Chrome UI, an extension's background).
    var sourceBrowser: Int32
    /// Window features or requested bounds (screen DIPs), when given.
    var bounds: CGRect?
    var url: String
    /// Chromium profile directory (the request context's cache path).
    var profilePath: String
    var persistentProfile = true
}

/// `cef_window_open_disposition_t` (`include/internal/cef_types.h`).
nonisolated enum CEFDisposition: Int32, Equatable, Sendable {
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

    init(raw: Int) {
        self = CEFDisposition(rawValue: Int32(clamping: raw)) ?? .unknown
    }

    /// How a page-requested tab opens in cmux. `nil`: no tab (Chromium
    /// saves or ignores it, or keeps it in the current tab).
    var tabDisposition: BrowserNewTabDisposition? {
        switch self {
        case .newBackgroundTab: .backgroundTab
        case .newPopup: .popup
        case .newForegroundTab, .newWindow, .singletonTab, .switchToTab, .newSplitView, .unknown: .foregroundTab
        case .offTheRecord: .foregroundTab
        case .currentTab, .saveToDisk, .ignoreAction, .newPictureInPicture: nil
        }
    }
}

/// A pane window the request can go to (one `CEFPaneHost` with a live
/// Chromium window).
nonisolated struct CEFWindowCandidate: Equatable, Sendable {
    /// Any tab of the window (`cmux_tab_add` and friends take it).
    var anchor: Int32
    var profilePath: String
    /// The window holds the requesting tab.
    var holdsSource: Bool
    /// The pane showed a Chromium tab most recently.
    var lastShown: Bool
    /// The pane is on screen.
    var visible: Bool
}
