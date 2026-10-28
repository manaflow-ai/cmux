import CoreGraphics
import Foundation

/// What the Chromium Host decides window requests with (task 031 of
/// plans/cmux-next/chrome-parity/p01-process.md): the state ``CEFWindowPolicy/decide(_:candidates:links:)``
/// reads in process, which cmux pushes because it cannot answer inside the host's navigation
/// (`cmux_shim_set_window_request_policy`). Chrome's browser process places a new WebContents from state
/// it already holds, without asking its UI (chrome/browser/ui/browser_navigator.cc,
/// `GetBrowserAndTabForDisposition`); the host's shim decides by `CEFShim/src/window_request_policy.h`.
nonisolated struct CEFWindowRequestPolicy: Equatable, Sendable {
    /// One pane window, by one of its tabs.
    struct Window: Equatable, Sendable {
        var anchor: Int32
        /// A popup panel: the anchor of the pane that opened it (its requests go there), else 0.
        var opener: Int32 = 0
        /// The window's store (`CEFRuntime.storeKey`).
        var store: String
        /// A live pane window a request may go to (no popup panel, no spare).
        var candidate: Bool
        var lastShown = false
        var visible = false
        /// The store is in memory only (an incognito window's).
        var offTheRecord = false

        /// `cmux_shim_window_flag_t` bits.
        var flags: Int64 {
            (candidate ? 1 : 0) | (lastShown ? 2 : 0) | (visible ? 4 : 0) | (offTheRecord ? 8 : 0)
        }
    }

    /// The last mouse-up on a page.
    struct Click: Equatable, Sendable {
        var browser: Int32
        var gesture: BrowserLinkGesture
        /// `NSEvent.timestamp` in ms (`CLOCK_UPTIME_RAW`, the clock the host reads).
        var uptimeMs: Int64
    }

    /// By anchor, ascending.
    var windows: [Window] = []
    /// By browser, ascending.
    var clicks: [Click] = []
    /// The directory of cmux's persistent `Profile-*` stores, normalized as the stores are.
    var profileRoot = ""
    var mapping: BrowserLinkClickMapping = .chrome

    /// The clicks of `context` that can still decide a request (at most `CEFLinkClicks.clickLifetime`
    /// old), so the pushed policy stays as small as the panes and one click.
    static func clicks(of context: CEFLinkContext) -> [Click] {
        context.clicks.compactMap { browser, record in
            guard context.now >= record.timestamp, context.now - record.timestamp <= CEFLinkClicks.clickLifetime else { return nil }
            return Click(browser: browser, gesture: record.gesture, uptimeMs: Int64((record.timestamp * 1_000).rounded(.down)))
        }
        .sorted { $0.browser < $1.browser }
    }

    /// Byte offsets of `cmux_shim_window_policy_window` (40 bytes) and `cmux_shim_window_policy_click`
    /// (24 bytes), as `cmux_cef_shim.h` documents them.
    static let windowStride = 40
    static let clickStride = 24

    /// Calls `body` with the C rows of the windows and the clicks, valid only during the call.
    func withRows<R>(_ body: (UnsafeRawPointer, Int32, UnsafeRawPointer, Int32) -> R) -> R {
        let windowRows = UnsafeMutableRawPointer.allocate(byteCount: max(windows.count, 1) * Self.windowStride, alignment: 8)
        let clickRows = UnsafeMutableRawPointer.allocate(byteCount: max(clicks.count, 1) * Self.clickStride, alignment: 8)
        defer {
            windowRows.deallocate()
            clickRows.deallocate()
        }
        for (index, click) in clicks.enumerated() {
            let row = clickRows + index * Self.clickStride
            row.storeBytes(of: Int64(click.browser), toByteOffset: 0, as: Int64.self)
            row.storeBytes(of: Int64(GestureCode(click.gesture).rawValue), toByteOffset: 8, as: Int64.self)
            row.storeBytes(of: click.uptimeMs, toByteOffset: 16, as: Int64.self)
        }
        // Every store's bytes in one buffer; each row points at its own run.
        let stores = Array(windows.map(\.store.utf8).joined())
        return stores.withUnsafeBytes { storeBytes in
            var offset = 0
            for (index, window) in windows.enumerated() {
                let row = windowRows + index * Self.windowStride
                let length = window.store.utf8.count
                row.storeBytes(of: Int64(window.anchor), toByteOffset: 0, as: Int64.self)
                row.storeBytes(of: Int64(window.opener), toByteOffset: 8, as: Int64.self)
                row.storeBytes(of: window.flags, toByteOffset: 16, as: Int64.self)
                row.storeBytes(of: storeBytes.baseAddress.map { $0 + offset }, toByteOffset: 24, as: UnsafeRawPointer?.self)
                row.storeBytes(of: length, toByteOffset: 32, as: Int.self)
                offset += length
            }
            return body(UnsafeRawPointer(windowRows), Int32(windows.count), UnsafeRawPointer(clickRows), Int32(clicks.count))
        }
    }

    /// cmux.json `browser.links.*` as `cmux_shim_link_action_t`: Cmd, Shift-Cmd, Shift, Option, middle.
    var actionCodes: [Int32] {
        [mapping.cmdClick, mapping.cmdShiftClick, mapping.shiftClick, mapping.optionClick, mapping.middleClick]
            .map { ActionCode($0).rawValue }
    }

    /// `cmux_shim_link_gesture_t`.
    enum GestureCode: Int32, Sendable {
        case plain = 0, cmd, cmdShift, shift, option, middle, middleShift

        init(_ gesture: BrowserLinkGesture) {
            switch gesture {
            case .plain: self = .plain
            case .cmd: self = .cmd
            case .cmdShift: self = .cmdShift
            case .shift: self = .shift
            case .option: self = .option
            case .middle: self = .middle
            case .middleShift: self = .middleShift
            }
        }
    }

    /// `cmux_shim_link_action_t`.
    enum ActionCode: Int32, Sendable {
        case currentTab = 0, backgroundTab, foregroundTab, linkPlacement, newWindow, download

        init(_ action: BrowserLinkAction) {
            switch action {
            case .currentTab: self = .currentTab
            case .backgroundTab: self = .backgroundTab
            case .foregroundTab: self = .foregroundTab
            case .linkPlacement: self = .linkPlacement
            case .newWindow: self = .newWindow
            case .download: self = .download
            }
        }
    }
}

/// A decision the Chromium Host made inside Chromium's navigation with the pushed
/// ``CEFWindowRequestPolicy`` (`CMUX_SHIM_WINDOW_REQUEST_RESULT`). cmux applies it as it applies its own
/// decision in process (`CEFWindowRequests.apply`).
nonisolated struct CEFWindowRequestResult: Equatable, Sendable {
    /// The request as cmux's log shows it; `profilePath` is the store the host resolved.
    var request: CEFWindowRequest
    var decision: CEFWindowDecision
    /// The Chromium window of an insert's anchor (0 otherwise): the window the new tab arrives in.
    var window: Int32
    /// The id the Chromium Host minted for an insert's tab (0: none, as from a host that mints none):
    /// the tab's AFTER_CREATED names it by this id, and cmux adopts it under it.
    var tab: Int32

    /// Decodes the event: `browser` the requesting tab, `window` the anchor's Chromium window,
    /// `anchor` the anchor, `packed` outcome | new tab << 8 | kind << 16 | disposition (7 bits) << 24 |
    /// user gesture << 31 | the tab's minted id << 32, `url`, and `placement` "x,y,width,height;store"
    /// (the bounds may be empty). Nil for what the host may not send (an unknown outcome or new tab, an
    /// insert with no anchor, a minted id that is no browser id or that is not an insert's): its output
    /// is untrusted, and such a result opens nothing.
    init?(browser: Int32, window: Int32, anchor: Int64, packed: Int64, url: String, placement: String) {
        guard let outcome = Outcome(rawValue: Int32(packed & 0xff)),
              let newTab = NewTab(rawValue: Int32((packed >> 8) & 0xff)),
              let tab = Int32(exactly: packed >> 32), tab >= 0, tab == 0 || outcome == .insert,
              let separator = placement.firstIndex(of: ";") else { return nil }
        let parts = placement[..<separator].split(separator: ",").compactMap { Double($0) }
        request = CEFWindowRequest(
            kind: CEFWindowRequest.Kind(rawValue: Int32((packed >> 16) & 0xff)) ?? .window,
            disposition: CEFDisposition(raw: Int((packed >> 24) & 0x7f)),
            sourceBrowser: browser,
            bounds: parts.count == 4 ? CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]) : nil,
            url: url,
            userGesture: (packed >> 31) & 1 != 0,
            profilePath: String(placement[placement.index(after: separator)...])
        )
        let disposition = newTab.disposition
        switch outcome {
        case .insert:
            guard anchor > 0, let anchor = Int32(exactly: anchor) else { return nil }
            decision = .insert(anchor: anchor, disposition: disposition)
        case .openInNewTab: decision = .openInNewTab(url: url, disposition: disposition)
        case .loadInSource: decision = .loadInSource(url: url)
        case .downloadInSource: decision = .downloadInSource(url: url)
        case .offTheRecord: decision = .openOffTheRecord(url: url)
        case .refuseNoWindow: decision = .refuse(.noWindow)
        }
        self.window = outcome == .insert ? window : 0
        self.tab = tab
    }

    /// `cmux_shim_window_outcome_t`.
    enum Outcome: Int32, Sendable {
        case insert = 1, openInNewTab, loadInSource, downloadInSource, offTheRecord, refuseNoWindow
    }

    /// `cmux_shim_new_tab_t`: `BrowserNewTabDisposition` on the wire.
    enum NewTab: Int32, Sendable {
        case foreground = 0, background, linkPlacement, popup, newWindow

        var disposition: BrowserNewTabDisposition {
            switch self {
            case .foreground: .foregroundTab
            case .background: .backgroundTab
            case .linkPlacement: .linkPlacement
            case .popup: .popup
            case .newWindow: .newWindow
            }
        }
    }
}
