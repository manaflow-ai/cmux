public import AppKit

/// The app's key state a press reads: `NSApp`'s, or a test's (test windows are never key).
public struct AppKeyState {
    /// The app's key window.
    public var keyWindow: NSWindow?
    /// The app's main window.
    public var mainWindow: NSWindow?
    /// Whether the app is the active app.
    public var isActive: Bool
    /// Whether a modal session runs.
    public var isModal: Bool

    /// A key state with these values.
    public init(keyWindow: NSWindow?, mainWindow: NSWindow?, isActive: Bool, isModal: Bool) {
        self.keyWindow = keyWindow
        self.mainWindow = mainWindow
        self.isActive = isActive
        self.isModal = isModal
    }
}

/// A view whose press acts without moving the key or the focus: a split divider, a column or row edge, the
/// sidebar's resize edge, and a sidebar row or rail mark whose press shows another workspace. Chrome's splitters
/// (views' `ResizeArea`, the DevTools and side panel splits) are not focusable: a press there starts the drag, and the
/// focused web content keeps the focus. Chrome's tab strip and its page are in one `NSWindow`, which stays key through
/// a tab click: the click only shows the other tab's view (`RenderWidgetHostViewMac::ShowWithVisibility`,
/// content/browser/renderer_host/render_widget_host_view_mac.mm).
@MainActor
public protocol KeyNeutralPressTarget: NSView {
    /// Whether `press` acts without moving the key. A view all of whose presses do (a divider) keeps the default.
    ///
    /// - Parameter press: The left mouse-down, not delivered yet.
    /// - Parameter hit: The view under the press: this view or a view inside it.
    /// - Returns: `true` when the press goes straight to this view and no window changes key; `false` when the press
    ///   takes the window's usual path (``FirstClickPolicy``, then AppKit).
    func keepsKey(for press: NSEvent, on hit: NSView) -> Bool
}

public extension KeyNeutralPressTarget {
    /// Every press on this view acts without moving the key.
    func keepsKey(for press: NSEvent, on hit: NSView) -> Bool { true }
}

/// What a window does with a press before AppKit gets it, for a window's `sendEvent(_:)`.
///
/// A left press that a ``KeyNeutralPressTarget`` keeps the key for (``KeyNeutralPressTarget/keepsKey(for:on:)``), while a
/// page of this window (a Chromium page, its DevTools or popup) holds the key, goes straight to that view, and so do
/// its drags and its release: nothing changes key, and the page keeps the focus. ``FirstClickPolicy`` made the window
/// key before such a press; for a divider that key change was the press's whole cost:
/// `-[NSThemeFrame _windowChangedKeyState]` redrew every control of the window, 101 view layouts and an 18.9 ms frame on
/// the drag's first refresh (RESIZE P0 7, px-col-drag-2-s1r, cmux21 120 Hz). For a sidebar row that shows another
/// workspace it put the switch's frame 14.8 to 18.2 ms behind the same switch by its key at p50 (SPACE SWITCH 4, hold
/// l1, aws-m4pro-8 120 Hz, 2 rounds: the press was 10.23 ms old when the switch started, against 2.7 to 3.0 ms with no
/// key change, and the key change's layout and draw landed in the
/// switch's frame); the switch gives the keyboard to the new workspace's content in the same turn, so the window was
/// key for nothing. In Chrome the page, the splitter and the tab strip share one window, which stays key.
///
/// Any other press while this window's Chromium page, a panel or no window holds the key acts at once
/// (``FirstClickPolicy``): made key first, AppKit gives the press to the view under it instead of spending it on making
/// the window key. A first click into a window of an inactive app, or behind another main window, keeps AppKit's rule:
/// the window activates, and a divider takes the first mouse, as Chrome's content view does.
///
/// ```swift
/// override func sendEvent(_ event: NSEvent) {
///     if presses.willSend(event, in: self) { return }
///     super.sendEvent(event)
/// }
/// ```
@MainActor
public final class WindowPressRouter {
    /// The app's key state (`NSApp`); a seam for tests.
    public var appKeyState: () -> AppKeyState = {
        AppKeyState(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow, isActive: NSApp.isActive, isModal: NSApp.modalWindow != nil)
    }
    /// Makes the window key before a press that acts at once; a seam for tests.
    public var makeKey: (NSWindow) -> Void = { $0.makeKey() }

    /// The key-neutral view that took a press, until its release; `nil` once the view is freed.
    private weak var pressed: NSView?
    /// Whether a press this router took is down, until its release. Kept apart from ``pressed``: AppKit never got that
    /// press, so its mouse-down view is an earlier press's view (a terminal). If the divider leaves the window mid-drag
    /// (a socket or an agent closes its pane), the rest of the press must not fall through to that view.
    private var claimed = false

    /// Makes the router.
    public init() {}

    /// Runs before `window` sends `event` on.
    ///
    /// - Parameter event: The event `window.sendEvent(_:)` got.
    /// - Parameter window: The window the event is for.
    /// - Returns: Whether the event was delivered here; the window then does not send it on.
    public func willSend(_ event: NSEvent, in window: NSWindow) -> Bool {
        let app = appKeyState()
        if routesKeyNeutral(event, in: window, app) { return true }
        if FirstClickPolicy().takesFirstClick(event, in: window, keyWindow: app.keyWindow, mainWindow: app.mainWindow,
                                              appIsActive: app.isActive, appIsModal: app.isModal) { makeKey(window) }
        return false
    }

    /// Gives a key-neutral press, its drags, force-click stages and release to the pressed view; `false` for any other event,
    /// and for a press its view does not keep the key for.
    /// Once the router took a press it keeps every left drag, force-click stage and the release until that release,
    /// and gives them to the view only while it is still in `window`.
    private func routesKeyNeutral(_ event: NSEvent, in window: NSWindow, _ app: AppKeyState) -> Bool {
        switch event.type {
        case .leftMouseDown:
            pressed = nil
            claimed = false
            guard app.isActive, !app.isModal, !window.isKeyWindow, window.attachedSheet == nil, let keyWindow = app.keyWindow,
                  keyWindow !== window, keyWindow.sheetParent == nil, isPage(keyWindow, of: window),
                  let hit = window.contentView?.hitTest(event.locationInWindow),
                  let view = sequence(first: hit, next: \.superview).first(where: { $0 is any KeyNeutralPressTarget }) as? any KeyNeutralPressTarget,
                  view.keepsKey(for: event, on: hit) else { return false }
            pressed = view
            claimed = true
            view.mouseDown(with: event)
            return true
        case .leftMouseDragged:
            guard claimed else { return false }
            if let pressed = livePressed(in: window) { pressed.mouseDragged(with: event) }
            return true
        case .leftMouseUp:
            guard claimed else { return false }
            let pressed = livePressed(in: window)
            self.pressed = nil
            claimed = false
            pressed?.mouseUp(with: event)
            return true
        case .pressure: // a force click's stages belong to its press, not to the view AppKit pressed last
            guard claimed else { return false }
            livePressed(in: window)?.pressureChange(with: event)
            return true
        default:
            return false
        }
    }

    /// The pressed view while it is still in `window`.
    private func livePressed(in window: NSWindow) -> NSView? {
        guard let pressed, pressed.window === window else { return nil }
        return pressed
    }

    /// Whether `keyWindow` is a page of `window`: a page window (``WindowOverlayHost/isPageWindow(_:)``: Chromium's page,
    /// a remote browser popup) under it, or a window a page opens over itself (DevTools, a page popup), with every window
    /// between it and `window` a page window. A key-capable panel of the window (the group-editor bubble, the screenshot
    /// section overlay) is not: it dismisses when it loses the key, so a divider press closes it as before.
    private func isPage(_ keyWindow: NSWindow, of window: NSWindow) -> Bool {
        var current = keyWindow
        while let parent = current.parent {
            guard WindowOverlayHost.isPageWindow(current) else { return false }
            if parent === window { return true }
            current = parent
        }
        return false
    }
}
