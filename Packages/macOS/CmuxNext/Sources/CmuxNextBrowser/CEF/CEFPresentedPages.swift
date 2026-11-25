public import AppKit
import CmuxNextDesign

/// The shim's calls for presented pages (``InTreePages/Presentation/presented``; `shim_presented.mm`, fork API 26 and
/// 30): a seam, so tests drive a presented page's view and hosting without Chromium. Every name the app uses lives
/// here.
struct CEFPresentedCalls {
    /// The shim's symbol names.
    nonisolated enum Symbol {
        static let sendMouse = "cmux_shim_browser_send_mouse"
        static let sendKey = "cmux_shim_browser_send_key"
        static let sendWheel = "cmux_shim_browser_send_wheel"
        static let edit = "cmux_shim_browser_edit"
        static let setPageFocus = "cmux_shim_browser_set_page_focus"
        static let setDetachedHosting = "cmux_shim_browser_set_detached_hosting"
        static let setCursorHandler = "cmux_shim_set_cursor_handler"
    }

    /// The first fork API with detached hosting, the embedder's key state and wheel phases.
    nonisolated static let forkAPI: Int32 = 30

    let sendMouse: (_ browser: Int32, _ mouse: ChromiumPageInput.Mouse) -> Void
    let sendWheel: (_ browser: Int32, _ wheel: ChromiumPageInput.Wheel) -> Void
    let sendKey: (_ browser: Int32, _ key: ChromiumPageInput.Key) -> Void
    let edit: (_ browser: Int32, _ command: ChromiumPageInput.Edit) -> Void
    /// The page's focus and key state, with no window made key (`cmux_shim_browser_set_page_focus`).
    let setPageFocus: (_ browser: Int32, _ focused: Bool) -> Void

    init(sendMouse: @escaping (_ browser: Int32, _ mouse: ChromiumPageInput.Mouse) -> Void,
         sendWheel: @escaping (_ browser: Int32, _ wheel: ChromiumPageInput.Wheel) -> Void,
         sendKey: @escaping (_ browser: Int32, _ key: ChromiumPageInput.Key) -> Void,
         edit: @escaping (_ browser: Int32, _ command: ChromiumPageInput.Edit) -> Void,
         setPageFocus: @escaping (_ browser: Int32, _ focused: Bool) -> Void) {
        self.sendMouse = sendMouse
        self.sendWheel = sendWheel
        self.sendKey = sendKey
        self.edit = edit
        self.setPageFocus = setPageFocus
    }

    /// The shim's calls; nil without a shim, below fork API 30, or when a symbol is missing.
    init?(shim: CEFShimLibrary?, apiVersion: Int32) {
        guard Self.support(shim: shim, apiVersion: apiVersion) == .supported, let shim,
              let mouse = shim.browserSendMouse, let key = shim.browserSendKey, let wheel = shim.browserSendWheel,
              let edit = shim.browserEdit, let focus = shim.browserSetPageFocus else { return nil }
        sendMouse = { browser, m in
            _ = mouse(browser, m.x, m.y, m.phase.rawValue, m.button, m.clickCount, m.buttons, m.modifierFlags)
        }
        sendWheel = { browser, w in
            _ = wheel(browser, w.x, w.y, w.dx, w.dy, w.precise ? 1 : 0, w.phase, w.momentumPhase,
                      Self.cefFlags(w.modifierFlags, buttons: 0))
        }
        sendKey = { browser, k in
            _ = key(browser, k.phase.rawValue, k.keyCode, Int32(k.character), Int32(k.unmodifiedCharacter), k.modifierFlags,
                    k.isRepeat ? 1 : 0)
        }
        self.edit = { browser, command in _ = edit(browser, command.rawValue) }
        setPageFocus = { browser, focused in _ = focus(browser, focused ? 1 : 0) }
    }

    /// Whether an engine can present pages, and why not: layer hosting (API 26) and detached hosting, the embedder's
    /// key state and wheel phases (API 30), with the shim's input calls.
    static func support(shim: CEFShimLibrary?, apiVersion: Int32) -> InTreePages.Engine {
        guard let shim else { return .unsupported("no engine") }
        guard apiVersion >= forkAPI else { return .unsupported("fork API \(apiVersion) < \(forkAPI)") }
        let missing: String? = shim.browserSetDetachedHosting == nil ? Symbol.setDetachedHosting
            : shim.browserSendMouse == nil ? Symbol.sendMouse
            : shim.browserSendKey == nil ? Symbol.sendKey
            : shim.browserSendWheel == nil ? Symbol.sendWheel
            : shim.browserEdit == nil ? Symbol.edit
            : shim.browserSetPageFocus == nil ? Symbol.setPageFocus
            : shim.setCursorHandler == nil ? Symbol.setCursorHandler : nil
        if let missing { return .unsupported("shim lacks \(missing)") }
        return .supported
    }

    /// `NSEvent.ModifierFlags` as `cef_event_flags_t` (`page_input.h` `CefFlags`), for the fork's wheel call.
    nonisolated static func cefFlags(_ flags: UInt64, buttons: Int32) -> Int32 {
        let ns = NSEvent.ModifierFlags(rawValue: UInt(flags))
        var cef: Int32 = 0
        if ns.contains(.capsLock) { cef |= 1 << 0 }
        if ns.contains(.shift) { cef |= 1 << 1 }
        if ns.contains(.control) { cef |= 1 << 2 }
        if ns.contains(.option) { cef |= 1 << 3 }
        if buttons & 1 != 0 { cef |= 1 << 4 }
        if buttons & 4 != 0 { cef |= 1 << 5 }
        if buttons & 2 != 0 { cef |= 1 << 6 }
        if ns.contains(.command) { cef |= 1 << 7 }
        if ns.contains(.numericPad) { cef |= 1 << 9 }
        return cef
    }
}

/// A presented page's input, in process: what its page view (``CEFHostedPageView``) forwards goes to the shim for the
/// browser the pane shows now (every tab of a pane shares one page window, ``CEFLayerHosting/browser``).
@MainActor
final class CEFPresentedInput: ChromiumPageInputSink {
    let calls: CEFPresentedCalls
    private let browser: () -> Int32?
    private let keyWillForward: (NSEvent) -> Void
    /// The page has cmux's keyboard (its view is its window's first responder).
    private(set) var isFocused = false
    /// Inputs forwarded (`debug.cef` `presented.inputs`).
    private(set) var forwarded = 0

    /// - Parameters:
    ///   - browser: The browser input goes to now; nil drops it (no page yet, or it closed).
    ///   - keyWillForward: Runs before a key down reaches the shim (``CEFRuntime/forwardedKeys`` by default).
    init(calls: CEFPresentedCalls, browser: @escaping () -> Int32?,
         keyWillForward: ((NSEvent) -> Void)? = nil) {
        self.calls = calls
        self.browser = browser
        self.keyWillForward = keyWillForward ?? { CEFRuntime.shared.forwardedKeys.note($0) }
    }

    func send(_ input: ChromiumPageInput) { // perf-hot: 5us cef-host-input (every forwarded input event)
        guard let browser = browser() else { return }
        forwarded += 1
        switch input {
        case .mouse(let mouse): calls.sendMouse(browser, mouse)
        case .wheel(let wheel): calls.sendWheel(browser, wheel)
        case .key(let key): calls.sendKey(browser, key)
        case .edit(let command): calls.edit(browser, command)
        }
    }

    func focusChanged(_ focused: Bool) {
        isFocused = focused
        guard let browser = browser() else { return }
        CEFHostView.trackerStats.presentedFocusChanges += 1
        calls.setPageFocus(browser, focused)
    }

    func willForwardKey(_ event: NSEvent) { keyWillForward(event) }
}

/// The key downs a presented page forwarded recently. CEF rebuilds each forwarded key as a new `NSEvent` (no window,
/// the original's time and key code); Chromium's key hooks (`cefKeyCallback`, the unhandled-key hook) look the
/// original up here, so cmux's key router sees the event it already decided (`DecidedKeyEvents`) and the page-first
/// offer it made for it (`PageFirstKeyOffer`), not a stranger.
struct CEFForwardedKeys {
    private var recent: [NSEvent] = []
    static let limit = 16

    mutating func note(_ event: NSEvent) {
        recent.append(event)
        if recent.count > Self.limit { recent.removeFirst(recent.count - Self.limit) }
    }

    /// The forwarded key down `event` was rebuilt from (same key code and time), or `event` itself.
    func original(for event: NSEvent) -> NSEvent {
        guard event.type == .keyDown, event.window == nil, event.timestamp != 0 else { return event }
        return recent.last { $0.keyCode == event.keyCode && $0.timestamp == event.timestamp } ?? event
    }
}

extension CEFHostView {
    /// The view's page is presented (``CEFLayerHosting/presents``): its page view is in this view, Chromium's window
    /// for it is headless.
    var presentsPage: Bool { layerHosting.presents }
}

/// What `debug.layers` reports of a presented page (``CEFTab/presentedPageCensus``).
public nonisolated struct PresentedPageCensus: Sendable, Equatable {
    /// The page view's frame in its window (zero when in none).
    public var frameInWindow: CGRect
    /// The hosted context (0: none yet).
    public var contextID: UInt32
    /// The page view takes the page's input.
    public var takesInput: Bool
    /// The page window is detached (headless, never ordered in).
    public var detached: Bool
    /// The page view is its window's first responder.
    public var isFirstResponder: Bool
    /// cmux last gave the page its focus.
    public var pageFocused: Bool
    /// The cursor Chromium last set over the page view (`arrow`, `iBeam`, `pointingHand`, `other`), nil before any.
    public var cursor: String?
}

extension CEFTab {
    /// `debug.layers` `page_views` entry of this tab's presented page view in `pane` (Foundation values, the in-tree
    /// entries' keys plus the presented page's own); nil while it is not presented, has no page view or is hidden.
    public func presentedPageViewFields(pane: String) -> [String: Any]? {
        guard let census = presentedPageCensus, !contentView.isHiddenOrHasHiddenAncestor else { return nil }
        let frame = census.frameInWindow
        return ["pane": pane, "parked": false, "parking": NSNull(), "presented": true, "rwhv_in_window": false,
                "frame_in_window": [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) },
                "widget_drawing": -1, "geometry": "presented", "context_id": Double(census.contextID),
                "detached": census.detached, "takes_input": census.takesInput, "first_responder": census.isFirstResponder,
                "page_focused": census.pageFocused, "cursor": census.cursor.map { $0 as Any } ?? NSNull()]
    }

    /// The presented page's state (`debug.layers`); nil while it is not presented or has no page view.
    public var presentedPageCensus: PresentedPageCensus? {
        let hosting = host.hostView.layerHosting
        guard hosting.presents, let page = hosting.page else { return nil }
        let cursor = page.pageCursor.map { cursor -> String in
            switch cursor {
            case NSCursor.arrow: "arrow"
            case NSCursor.iBeam: "iBeam"
            case NSCursor.pointingHand: "pointingHand"
            default: "other"
            }
        }
        return PresentedPageCensus(frameInWindow: page.window == nil ? .zero : page.convert(page.bounds, to: nil),
                                   contextID: page.contextID, takesInput: page.input != nil, detached: hosting.isDetached,
                                   isFirstResponder: page.window?.firstResponder === page,
                                   pageFocused: hosting.presentedInput?.isFocused ?? false, cursor: cursor)
    }
}
