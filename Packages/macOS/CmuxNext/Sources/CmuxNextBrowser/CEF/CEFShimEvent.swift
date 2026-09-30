import Foundation

/// A shim callback, decoded (cmux_shim_event_kind_t in cmux_cef_shim.h).
nonisolated enum CEFShimEvent: Equatable, Sendable {
    case contextInitialized
    /// `request` is the create-window token, 0 for tabs added to an existing
    /// window (cmux_tab_add, chrome.tabs.create, target=_blank).
    case afterCreated(browser: Int32, request: Int32, window: Int32)
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
    case unknown(kind: Int32)

    init(kind: Int32, browser: Int32, request: Int32, a: Int64, b: Int64, s1: String, s2: String) {
        switch kind {
        case 1: self = .contextInitialized
        case 2: self = .afterCreated(browser: browser, request: request, window: Int32(truncatingIfNeeded: a))
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
    case unknown = -1
}
