public import AppKit

/// The view that holds an in-tree Chromium page inside its pane (the browser's page container in a `CEFHostView`).
///
/// A view is a page view when it is a container or inside one: the page's `RenderWidgetHostViewCocoa` (which changes
/// with each renderer, so it is never named by class) and the `WebContentsViewCocoa` around it.
@MainActor
///
/// It names no pane: the browser knows only its own tab key, never the cmux pane the page shows in, and a tab can move
/// between panes. The window reads the pane from where the container sits in its view tree (``InTreePageFocus/refuses(_:in:event:focusModelApplies:focusedPane:paneOf:routeTarget:isActive:)``'s
/// `paneOf`), the same way it classifies every other responder.
public protocol InTreePageContainer: NSView {
    /// What `debug.layers` reports of the page (its census row).
    var inTreeCensus: InTreePageCensus { get }
}

/// One in-tree page in `debug.layers` `page_views`.
public struct InTreePageCensus: Equatable, Sendable {
    /// Whether the page's current `RenderWidgetHostViewCocoa` is in the cmux window (`rwhv_in_window`).
    public var contentInWindow: Bool
    /// `cmux_browser_in_tree_widget_drawing`: 0 the headless widget stopped drawing (expected), 1 it still draws, -1
    /// the page is not in tree.
    public var widgetDrawing: Int

    public init(contentInWindow: Bool, widgetDrawing: Int) {
        self.contentInWindow = contentInWindow
        self.widgetDrawing = widgetDrawing
    }
}

/// Who may give an in-tree page the keyboard (plans/cmux-next/in-tree-pages.md, Focus).
///
/// The cmux window is always key, so a page takes the keyboard only by becoming the window's first responder, and every
/// such move passes the window's gate (`ShellWindow.makeFirstResponder`, `ResponderMoveGate`). Chromium also asks for
/// it by itself: after a load, from `CefBrowserHost::SetFocus`, a page's `window.focus()`, a tab activation. The gate
/// lets a page view in only for the person's own input aimed at it, cmux's focus model applying a move to its pane, or
/// a grant cmux makes itself (``granting(_:_:)``, the browser's own focus call to Chromium).
@MainActor
public final class InTreePageFocus {
    /// The process's grants and counters.
    public static let shared = InTreePageFocus()

    init() {}

    /// The containers cmux grants the keyboard to now (nested grants stack).
    private var grants: [ObjectIdentifier] = []

    /// Moves the gate let a page view make (`debug.focus` `in_tree.allowed`).
    public private(set) var allowed = 0
    /// Moves the gate refused (`debug.focus` `in_tree.refused`), and the last one's reason.
    public private(set) var refused = 0
    public private(set) var lastRefusal: String?

    /// Runs `body` with `container`'s page allowed to take the keyboard: cmux's own grant (it asks Chromium to focus the
    /// page, and Chromium makes its view first responder inside that call).
    public func granting<T>(_ container: any InTreePageContainer, _ body: () -> T) -> T {
        grants.append(ObjectIdentifier(container))
        defer { grants.removeLast() }
        return body()
    }

    /// Whether cmux is granting `container` the keyboard now.
    public func isGranting(_ container: any InTreePageContainer) -> Bool {
        grants.contains(ObjectIdentifier(container))
    }

    /// The page container `view` is, or is inside; nil for any other view.
    public static func container(of view: NSView?) -> (any InTreePageContainer)? {
        var current = view
        while let next = current {
            if let container = next as? any InTreePageContainer { return container }
            current = next.superview
        }
        return nil
    }

    /// The page containers holding a page in `window`'s view tree, in tree order.
    public static func containers(in window: NSWindow) -> [any InTreePageContainer] {
        guard let root = window.contentView else { return [] }
        var found: [any InTreePageContainer] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let page = view as? any InTreePageContainer {
                if !page.subviews.isEmpty { found.append(page) }
                continue
            }
            stack.append(contentsOf: view.subviews.reversed())
        }
        return found
    }

    /// Grants after which cmux took the key window back from a window Chromium made key (`debug.focus`
    /// `in_tree.keys_taken_back`, ``takesKeysBack(from:before:owner:)``).
    public private(set) var keysTakenBack = 0

    /// Whether, after a grant to an in-tree page shown in `owner`, `owner` takes the key window back from `key`.
    ///
    /// Chromium's focus call (`CefBrowserHost::SetFocus`) activates the page's own window. In tree that window is
    /// headless: the page's view is in the cmux window, and the headless window holds no view that takes keys. Left key,
    /// every key went there: the key router saw a window no cmux window owns and matched no cmux shortcut (Cmd-D,
    /// Cmd-Shift-D, Cmd-Shift-Return did nothing; only menu keys such as Cmd-T ran), and the page got no keys either,
    /// until a click made the cmux window key again (sweep-06675353 D1). A click never had this: it makes the window it
    /// lands in key. So a grant, like a click, leaves the keys with the cmux window.
    ///
    /// - Parameters:
    ///   - key: The key window after the grant.
    ///   - before: The key window before it.
    ///   - owner: The cmux window the page shows in.
    /// - Returns: True when the grant made `key` key and no cmux window owns it (it is not `owner` or a child or
    ///   sheet of it); a key window the grant did not change is never taken.
    public static func takesKeysBack(from key: NSWindow?, before: NSWindow?, owner: NSWindow) -> Bool {
        guard let key, key !== before else { return false }
        var current: NSWindow? = key
        while let window = current {
            if window === owner { return false }
            current = window.parent ?? window.sheetParent
        }
        return true
    }

    /// cmux took the key window back after a grant.
    public func noteKeysTakenBack() { keysTakenBack += 1 }

    func noteAllowed() { allowed += 1 }

    func noteRefused(_ reason: String) {
        refused += 1
        lastRefusal = reason
    }

    /// Whether `window` refuses to make `responder` (a page view) its first responder. False for any responder that is
    /// not a page view, and with the mode off.
    ///
    /// - Parameters:
    ///   - responder: The responder asked for.
    ///   - window: The window whose `makeFirstResponder` runs.
    ///   - event: The input event being dispatched, nil outside one.
    ///   - focusModelApplies: The window's focus model is applying its own move.
    ///   - focusedPane: The pane the focus model has focused.
    ///   - paneOf: The cmux pane a page container shows in, read from the window's view tree (nil: in no pane).
    ///   - routeTarget: The responder a routed move (`FocusRoute`) names, nil outside one.
    ///   - isActive: Whether the mode is on (``InTreePages/isActive`` by default).
    /// - Returns: True when the move must be refused.
    public func refuses(_ responder: NSResponder?, in window: NSWindow, event: NSEvent?, focusModelApplies: Bool,
                        focusedPane: () -> String?, paneOf: (NSView) -> String?, routeTarget: NSResponder?,
                        isActive: Bool = InTreePages.shared.isActive) -> Bool {
        guard isActive, let view = responder as? NSView, let container = Self.container(of: view) else { return false }
        if let decision = decide(view, container: container, in: window, event: event, focusModelApplies: focusModelApplies,
                                 focusedPane: focusedPane, paneOf: paneOf, routeTarget: routeTarget) {
            noteRefused(decision)
            return true
        }
        noteAllowed()
        return false
    }

    /// Nil when the move is allowed, else why it is refused.
    private func decide(_ view: NSView, container: any InTreePageContainer, in window: NSWindow, event: NSEvent?,
                        focusModelApplies: Bool, focusedPane: () -> String?, paneOf: (NSView) -> String?,
                        routeTarget: NSResponder?) -> String? {
        // A move to where the keys are already changes nothing.
        if window.firstResponder === view { return nil }
        if isGranting(container) { return nil }
        if let routeTarget, routeTarget === view { return nil }
        if let event, Self.event(event, isAimedAt: container, in: window) { return nil }
        if focusModelApplies, let pane = paneOf(container), focusedPane() == pane { return nil }
        if view.isHiddenOrHasHiddenAncestor { return "page not shown" }
        return event == nil ? "no input event or focus route" : "input event aimed elsewhere"
    }

    /// Whether `event`, being dispatched in `window`, is aimed at the page in `container`: a press, drag or release
    /// whose hit view is inside it, or a key while the page holds the keys (its own moves inside the page).
    public static func event(_ event: NSEvent, isAimedAt container: any InTreePageContainer, in window: NSWindow) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard event.window == nil || event.window === window, let frame = window.contentView?.superview,
                  let hit = frame.hitTest(frame.convert(event.locationInWindow, from: nil)) else { return false }
            return hit === container || hit.isDescendant(of: container)
        case .keyDown, .keyUp, .flagsChanged:
            guard let current = window.firstResponder as? NSView else { return false }
            return current === container || current.isDescendant(of: container)
        default:
            return false
        }
    }
}
