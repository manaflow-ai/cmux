import CoreGraphics
import Foundation

/// Where a tab Chromium wants to open goes.
nonisolated enum CEFLinkPlacement: Equatable, Sendable, Decodable {
    /// A cmux tab (or window) with this disposition.
    case tab(BrowserNewTabDisposition)
    /// No new tab: the opener loads the URL (a modified click mapped to
    /// the current tab).
    case opener
    /// No new tab: the opener downloads the URL into the Downloads folder
    /// (`CEFDownloads`).
    case download
    /// Chromium handles it alone (the current tab, an ignored action,
    /// picture in picture): no cmux tab.
    case chromium
}

/// The one decision for Chromium link dispositions, through the same
/// `BrowserLinkClickMapping` WebKit uses.
nonisolated enum CEFLinkClicks {
    /// Chromium reports how it wants to open a link (`ui::DispositionFromClick`): NEW_BACKGROUND_TAB
    /// for Cmd-click and middle click, NEW_WINDOW for Shift-click, SAVE_TO_DISK for Option-click,
    /// and NEW_FOREGROUND_TAB for both Shift-Cmd-click and a plain `target=_blank` link. `click`,
    /// the last mouse-up on the requesting page when it is at most a second old at `now`, tells
    /// those apart. A request without a user gesture (a script) never follows a modified-click
    /// setting. The rule is cmux-browser-rules' (`cef_placement`, with its tests).
    static func placement(for disposition: CEFDisposition, userGesture: Bool, click: CEFLinkClickRecord?,
                          now: TimeInterval, mapping: BrowserLinkClickMapping) -> CEFLinkPlacement {
        struct Request: Encodable {
            let disposition: CEFDisposition
            let userGesture: Bool
            let click: CEFLinkClickRecord?
            let now: TimeInterval
            let mapping: BrowserLinkClickMapping
        }
        let request = Request(disposition: disposition, userGesture: userGesture, click: click, now: now, mapping: mapping)
        return BrowserRules.call("browser_rules_cef_link_placement", request, as: CEFLinkPlacement.self)
            ?? .tab(.foregroundTab)
    }

    /// Pure: the page a mouse-up landed on. Only a click in a page window
    /// (a child window of the cmux window holding the page's host view)
    /// counts, inside the host view and outside native UI over it; a click
    /// in a cmux window itself (`parent` nil) never does.
    static func browser(clickedIn window: ObjectIdentifier, parent: ObjectIdentifier?, at point: CGPoint,
                        targets: [CEFClickTarget]) -> Int32? {
        guard let parent, parent != window else { return nil }
        return targets.first { target in
            target.hostWindow == parent && target.frame.contains(point) && !target.occlusions.contains { $0.contains(point) }
        }?.browser
    }
}

/// What the runtime knows when it places a tab Chromium wants to open: the
/// user's mapping, the last click on each Chromium page and the current time.
nonisolated struct CEFLinkContext: Equatable, Sendable {
    var mapping: BrowserLinkClickMapping = .chrome
    /// By browser id; a request only reads its source page's click.
    var clicks: [Int32: CEFLinkClickRecord] = [:]
    /// Seconds since boot, as `NSEvent.timestamp`.
    var now: TimeInterval = 0

    /// How a request from page `source` (0: no page) opens.
    func placement(for disposition: CEFDisposition, source: Int32, userGesture: Bool) -> CEFLinkPlacement {
        CEFLinkClicks.placement(for: disposition, userGesture: userGesture, click: source != 0 ? clicks[source] : nil,
                                now: now, mapping: mapping)
    }

    /// What the window rules read of this context for a request from page `source`.
    struct Facts: Encodable {
        let mapping: BrowserLinkClickMapping
        let click: CEFLinkClickRecord?
        let now: TimeInterval
    }

    func facts(source: Int32) -> Facts {
        Facts(mapping: mapping, click: source != 0 ? clicks[source] : nil, now: now)
    }
}
