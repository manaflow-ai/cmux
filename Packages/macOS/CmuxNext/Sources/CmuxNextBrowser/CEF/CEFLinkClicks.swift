import CoreGraphics
import Foundation

/// Where a tab Chromium wants to open goes.
nonisolated enum CEFLinkPlacement: Equatable, Sendable {
    /// A cmux tab (or window) with this disposition.
    case tab(BrowserNewTabDisposition)
    /// No new tab: the opener loads the URL (a modified click mapped to
    /// the current tab).
    case opener
    /// Chromium handles it alone (the current tab, a download, an ignored
    /// action, picture in picture): no cmux tab.
    case chromium
}

/// The one decision for Chromium link dispositions, through the same
/// `BrowserLinkClickMapping` WebKit uses.
nonisolated enum CEFLinkClicks {
    /// A click older than this did not cause the request.
    static let clickLifetime: TimeInterval = 1

    /// Pure. Chromium reports how it wants to open a link
    /// (`ui::DispositionFromClick`): NEW_BACKGROUND_TAB for Cmd-click and
    /// middle click, NEW_WINDOW for Shift-click, SAVE_TO_DISK for
    /// Option-click, and NEW_FOREGROUND_TAB for both Shift-Cmd-click and a
    /// plain `target=_blank` link. `click`, the last mouse-up on the
    /// requesting page when it is at most `clickLifetime` old at `now`, is
    /// read only to tell those two apart; a stale or missing click means a
    /// plain target=_blank (a selected tab). Every other disposition keeps
    /// Chromium's meaning, so NEW_BACKGROUND_TAB is `cmdClick` (Chromium
    /// does not tell a middle click from Cmd-click).
    static func placement(for disposition: CEFDisposition, click: CEFLinkClickRecord?, now: TimeInterval,
                          mapping: BrowserLinkClickMapping) -> CEFLinkPlacement {
        switch disposition {
        case .newBackgroundTab: .tab(.backgroundTab)
        case .newPopup: .tab(.popup)
        case .newForegroundTab, .newWindow, .singletonTab, .switchToTab, .newSplitView, .unknown, .offTheRecord: .tab(.foregroundTab)
        case .currentTab, .saveToDisk, .ignoreAction, .newPictureInPicture: .chromium
        }
    }

    /// Pure: the page a mouse-up landed on. Only a click in a page window
    /// (a child window of the cmux window holding the page's host view)
    /// counts, inside the host view and outside native UI over it; a click
    /// in a cmux window itself (`parent` nil) never does.
    static func browser(clickedIn window: ObjectIdentifier, parent: ObjectIdentifier?, at point: CGPoint,
                        targets: [CEFClickTarget]) -> Int32? {
        return targets.first { target in
            target.frame.contains(point) || parent == nil
        }?.browser
    }

    static func unusedBrowser(clickedIn window: ObjectIdentifier, parent: ObjectIdentifier?, at point: CGPoint,
                              targets: [CEFClickTarget]) -> Int32? {
        guard let parent, parent != window else { return nil }
        return targets.first { target in
            target.hostWindow == parent && target.frame.contains(point) && !target.occlusions.contains { $0.contains(point) }
        }?.browser
    }

    private static func placement(chromeDefault gesture: BrowserLinkGesture) -> CEFLinkPlacement {
        BrowserLinkClickMapping.chrome.action(for: gesture).newTabDisposition.map(CEFLinkPlacement.tab) ?? .tab(.foregroundTab)
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
    func placement(for disposition: CEFDisposition, source: Int32) -> CEFLinkPlacement {
        CEFLinkClicks.placement(for: disposition, click: source != 0 ? clicks[source] : nil, now: now, mapping: mapping)
    }
}
