import CoreGraphics
import Foundation

/// A shim callback, decoded (cmux_shim_event_kind_t in cmux_cef_shim.h).
nonisolated enum CEFShimEvent: Equatable, Sendable {
    case contextInitialized
    /// `request` is the create-window token, 0 for tabs added to an existing
    /// window (cmux_tab_add, chrome.tabs.create, target=_blank). `window` is
    /// 0 while the tab is in no window yet (a popup before Chromium places
    /// it). `opener` and `disposition` name the page that opened a popup
    /// and how (0 and `.unknown` otherwise).
    case afterCreated(browser: Int32, request: Int32, window: Int32, created: CEFCreatedBy = .none)
    case beforeClose(browser: Int32)
    case address(browser: Int32, url: String)
    case title(browser: Int32, title: String)
    case favicon(browser: Int32, url: String)
    case loadingState(browser: Int32, loading: Bool, canGoBack: Bool, canGoForward: Bool)
    case loadStart(browser: Int32, url: String)
    case loadEnd(browser: Int32, httpStatus: Int)
    case loadError(browser: Int32, code: Int, text: String, url: String)
    case progress(browser: Int32, value: Double)
    case fullscreen(browser: Int32, entering: Bool)
    case devToolsResult(browser: Int32, messageID: Int32, success: Bool, json: String)
    case findResult(browser: Int32, count: Int, activeOrdinal: Int, isFinal: Bool)
    case closeRequested(browser: Int32)
    case tab(CEFForkTabEvent, browser: Int32, window: Int32, value: Int)
    case popup(browser: Int32, url: String, disposition: Int)
    /// Reply to an async site call (`cmux_shim_visit_cookies`,
    /// `cmux_shim_delete_cookies`): `value` is 1 or the deleted count.
    case reply(browser: Int32, id: Int32, value: Int64, json: String)
    /// Chromium's page context menu; finish with `cmux_shim_context_menu_done(token, …)`.
    case contextMenu(browser: Int32, token: Int32, x: Int, y: Int, itemsJSON: String, paramsJSON: String)
    /// DevTools events name the inspected page's browser.
    case devToolsWillOpen(browser: Int32)
    case devToolsOpened(browser: Int32, devTools: Int32, docked: Bool)
    case devToolsClosed(browser: Int32, devTools: Int32)
    /// The tab's renderer ended unexpectedly: `status` is
    /// `cef_termination_status_t`, `code` the exit code or signal.
    case renderTerminated(browser: Int32, status: Int, code: Int, text: String)
    /// The renderer stopped handling input (hang monitor, 15 s).
    case renderUnresponsive(browser: Int32)
    case renderResponsive(browser: Int32)
    /// A Chromium command that would open a Chromium window; the shim blocked
    /// it (`IDC_*` id).
    case chromeCommand(browser: Int32, command: Int32)
    /// The navigation guard cancelled a main-frame navigation to `url`.
    case navigationReroute(browser: Int32, url: String, isRedirect: Bool)
    /// The page did not handle a key down (Windows key code): a plain
    /// Escape, or a letter outside editable fields with `shift`.
    case keyUnhandled(browser: Int32, keyCode: Int, shift: Bool)
    /// An extension install or permission prompt (fork API 12); prompt 0
    /// is the "installed" notice.
    case installPrompt(browser: Int32, promptID: Int32, json: String)
    /// chrome.omnibox suggestions for a keyword-session request (fork API 12).
    case omniboxSuggestions(requestID: Int32, extensionID: String, json: String)
    /// Focus left the page past its last (`forward`) or first element.
    case takeFocus(browser: Int32, forward: Bool)
    /// A raw DevTools protocol message (`cmux_shim_devtools_send` replies,
    /// events of a watched browser): the JSON as Chromium sent it.
    case devToolsMessage(browser: Int32, json: String)
    /// A watched profile preference changed (`cmux_shim_pref_watch`).
    case preferenceChanged(name: String, profilePath: String)
    case unknown(kind: Int32)

    init(kind: Int32, browser: Int32, request: Int32, a: Int64, b: Int64, s1: String, s2: String) {
        switch kind {
        case 1: self = .contextInitialized
        case 2:
            self = .afterCreated(browser: browser, request: request, window: Int32(truncatingIfNeeded: a),
                                 created: CEFCreatedBy(packed: b, features: s1))
        case 3: self = .beforeClose(browser: browser)
        case 4: self = .address(browser: browser, url: s1)
        case 5: self = .title(browser: browser, title: s1)
        case 6: self = .favicon(browser: browser, url: s1)
        case 7: self = .loadingState(browser: browser, loading: a & 1 != 0, canGoBack: a & 2 != 0, canGoForward: a & 4 != 0)
        case 8: self = .loadStart(browser: browser, url: s1)
        case 9: self = .loadEnd(browser: browser, httpStatus: Int(a))
        case 10: self = .loadError(browser: browser, code: Int(a), text: s1, url: s2)
        case 11: self = .progress(browser: browser, value: min(max(Double(a) / 1000, 0), 1))
        case 12: self = .fullscreen(browser: browser, entering: a != 0)
        case 13: self = .devToolsResult(browser: browser, messageID: request, success: a != 0, json: s1)
        case 14:
            self = .findResult(
                browser: browser, count: Int(a),
                activeOrdinal: Int(Int32(truncatingIfNeeded: b)), isFinal: (b >> 32) & 1 != 0
            )
        case 15: self = .closeRequested(browser: browser)
        case 16:
            self = .tab(CEFForkTabEvent(rawValue: request) ?? .unknown, browser: browser,
                        window: Int32(truncatingIfNeeded: a), value: Int(b))
        case 17: self = .popup(browser: browser, url: s1, disposition: Int(a))
        case 18: self = .reply(browser: browser, id: request, value: a, json: s1)
        case 19: self = .contextMenu(browser: browser, token: request, x: Int(a), y: Int(b), itemsJSON: s1, paramsJSON: s2)
        case 20: self = .devToolsWillOpen(browser: browser)
        case 21: self = .devToolsOpened(browser: browser, devTools: Int32(truncatingIfNeeded: a), docked: b != 0)
        case 22: self = .devToolsClosed(browser: browser, devTools: Int32(truncatingIfNeeded: a))
        case 23: self = .renderTerminated(browser: browser, status: Int(a), code: Int(b), text: s1)
        case 24: self = .renderUnresponsive(browser: browser)
        case 25: self = .renderResponsive(browser: browser)
        case 26: self = .chromeCommand(browser: browser, command: request)
        case 27: self = .navigationReroute(browser: browser, url: s1, isRedirect: a != 0)
        case 28: self = .keyUnhandled(browser: browser, keyCode: Int(a), shift: b & 1 != 0)
        case 29: self = .installPrompt(browser: browser, promptID: request, json: s1)
        case 30: self = .omniboxSuggestions(requestID: request, extensionID: s1, json: s2)
        case 31: self = .takeFocus(browser: browser, forward: a != 0)
        case 32: self = .devToolsMessage(browser: browser, json: s1)
        case 33: self = .preferenceChanged(name: s1, profilePath: s2)
        default: self = .unknown(kind: kind)
        }
    }
}

/// `cmux_tab_event_t` of the fork (include/cef_cmux.h).
nonisolated enum CEFForkTabEvent: Int32, Sendable {
    case inserted = 0
    case activated = 1
    case moved = 2
    case removed = 3
    case extensionActionsChanged = 4
    case extensionPopupClosed = 5
    /// A Chromium Browser was destroyed; value = remaining window count.
    case windowDestroyed = 6
    /// An extension was installed, removed, enabled or disabled (fork API v3).
    case extensionsChanged = 7
    /// The DevTools menu chose a dock side (fork API 12); value = 0
    /// undocked, 1 left, 2 bottom, 3 right.
    case devToolsDockSide = 8
    /// Chromium created a Browser (window) outside cmux; the fork keeps it
    /// hidden, moves its tabs to a pane window and closes it (fork API 8).
    /// value = the Browser type.
    case foreignBrowserBlocked = 9
    /// A chrome.windows.create popup is kept hidden for cmux (fork API 11,
    /// only while popup windows are enabled); value = the Browser type.
    case popupWindowCreated = 10
    /// Its bounds changed (chrome.windows.update).
    case popupWindowBounds = 11
    /// The window's side panel was shown, hidden, resized or changed
    /// (fork API 13); value = 1 when visible.
    case sidePanelChanged = 12
    case unknown = -1
}

/// The page that opened a tab and how (AFTER_CREATED `b` and `s1`).
nonisolated struct CEFCreatedBy: Equatable, Sendable {
    var opener: Int32
    var disposition: CEFDisposition
    /// Popup window features (screen DIPs), when the page gave a size.
    var features: CGRect?

    static let none = CEFCreatedBy(opener: 0, disposition: .unknown, features: nil)

    init(opener: Int32, disposition: CEFDisposition, features: CGRect?) {
        self.opener = opener
        self.disposition = disposition
        self.features = features
    }

    init(packed: Int64, features: String) {
        opener = Int32(truncatingIfNeeded: packed >> 32)
        disposition = CEFDisposition(raw: Int(Int32(truncatingIfNeeded: packed & 0xffff_ffff)))
        let parts = features.split(separator: ",").compactMap { Double($0) }
        self.features = parts.count == 4 ? CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]) : nil
    }
}
