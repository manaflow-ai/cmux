import CoreGraphics
import Foundation

/// The tabs pages asked Chromium to open, for a new tab the shim could not
/// match to its request.
///
/// The shim matches a new tab to its opener's request (OnBeforePopup) by
/// the tab's visible URL at OnAfterCreated. A scripted `window.open` has no
/// visible URL yet then, and a modified click (Cmd-click, Shift-click; CEF's
/// OnOpenURLFromTab) creates a tab Chromium reports without an opener: such
/// a tab arrived with no disposition, gesture or window features, so a sized
/// popup opened as a tab, a Cmd-click took focus, and a tab without an
/// opener was closed. The runtime records every request (the shim's POPUP
/// event) and the bounds of the popup window request that follows it, and a
/// tab the shim left unmatched takes its opener's oldest live request.
nonisolated struct CEFPopupLedger: Equatable, Sendable {
    struct Request: Equatable, Sendable {
        var opener: Int32
        var url: String
        var disposition: CEFDisposition
        var userGesture: Bool
        var bounds: CGRect?
        /// Seconds since boot.
        var at: TimeInterval
    }

    /// A page and the Chromium window it is in (`cmux_shim_tab_window_id`).
    struct WindowPage: Equatable, Sendable {
        var browser: Int32
        var window: Int32
        /// The page the window was created for, not a popup waiting there
        /// for a window of its own.
        var isOwner: Bool
    }

    /// A request older than this did not cause a tab created now (the
    /// shim's `PendingPopups::kLifetimeMs`, Chrome's user activation span).
    static let lifetime: TimeInterval = 5
    static let limitPerOpener = 8

    private(set) var requests: [Request] = []

    var isEmpty: Bool { requests.isEmpty }

    /// A page asked for a tab or popup (the shim's POPUP event). Requests
    /// that open no tab (the current tab, a download) are not recorded.
    mutating func recordRequest(opener: Int32, url: String, disposition: CEFDisposition, userGesture: Bool,
                                at now: TimeInterval) {
        switch disposition {
        case .newForegroundTab, .newBackgroundTab, .newPopup, .newWindow: break
        default: return
        }
        expire(now)
        requests.append(Request(opener: opener, url: url, disposition: disposition, userGesture: userGesture,
                                bounds: nil, at: now))
        let mine = requests.indices.filter { requests[$0].opener == opener }
        if mine.count > Self.limitPerOpener { requests.remove(at: mine[0]) }
    }

    /// Chromium asked for a window for `source`'s newest request (a popup
    /// with window features): its bounds are the popup's features.
    mutating func recordWindowBounds(source: Int32, bounds: CGRect, at now: TimeInterval) {
        expire(now)
        guard let index = requests.lastIndex(where: { $0.opener == source && $0.bounds == nil }) else { return }
        requests[index].bounds = bounds
    }

    /// The opener and request of a new tab: `created` as the shim reported
    /// it, its request consumed, when the shim matched it; else `opener`'s
    /// oldest live request (the one with the tab's URL first, when the shim
    /// knew the URL).
    mutating func resolve(_ created: CEFCreatedBy, opener: Int32, now: TimeInterval) -> CEFCreatedBy {
        expire(now)
        var resolved = created
        resolved.opener = opener
        let mine = requests.indices.filter { requests[$0].opener == opener }
        let sameURL = mine.first { created.url != nil && requests[$0].url == created.url }
        if created.disposition != .unknown {
            if let index = sameURL {
                if resolved.features == nil { resolved.features = requests[index].bounds }
                requests.remove(at: index)
            }
            return resolved
        }
        guard let index = sameURL ?? mine.first else { return resolved }
        let request = requests.remove(at: index)
        resolved.disposition = request.disposition
        resolved.userGesture = request.userGesture
        resolved.features = created.features ?? request.bounds
        if resolved.url == nil, !request.url.isEmpty { resolved.url = request.url }
        return resolved
    }

    mutating func forget(opener: Int32) {
        requests.removeAll { $0.opener == opener }
    }

    private mutating func expire(_ now: TimeInterval) {
        requests.removeAll { now < $0.at || now - $0.at > Self.lifetime }
    }

    /// The page whose window Chromium put a new tab in: the tab's opener
    /// when Chromium reported none.
    static func owner(ofWindow window: Int32, among pages: [WindowPage]) -> Int32? {
        guard window != 0 else { return nil }
        return pages.first { $0.window == window && $0.isOwner }?.browser
    }
}
