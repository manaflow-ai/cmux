public import AppKit
public import SwiftUI

/// A button that shows the pointing hand while the pointer is over it and it is enabled, and the
/// arrow while it is disabled (Leo 2026-10-21: "STOP BUTTON, I HOVER OVER IT, MY CURSOR SHOULD
/// ALSO SEE IT AS CLICKABLE"). The shared chrome buttons (toolbar band, pane toolbar, tab bar,
/// sidebar, dialogs, toasts) inherit it, so each says it can be clicked the same way.
///
/// A cursor rect in the key window: AppKit owns the rect and drops it when the button hides,
/// leaves its window or scrolls out of view, so no pushed cursor is ever left behind. A change of
/// `isEnabled` rebuilds it at once. Cursor rects do nothing while another window has the key (a
/// Chromium page is a child window that takes it), so `cursorTracker` sets the hand itself then.
open class ClickableButton: NSButton {
    /// Sets the hand while another window of the app has the key (`ClickableCursorTracker`).
    private(set) lazy var cursorTracker = ClickableCursorTracker(self) { [weak self] in self?.isEnabled ?? false }

    /// The cursor over a button: the pointing hand while enabled, none (the arrow) while disabled.
    public static func hoverCursor(isEnabled: Bool) -> NSCursor? { isEnabled ? .pointingHand : nil }

    /// This button's cursor now (`hoverCursor(isEnabled:)`).
    public var hoverCursor: NSCursor? { Self.hoverCursor(isEnabled: isEnabled) }

    override open var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            cursorTracker.clickableStateDidChange()
            // AppKit rebuilds cursor rects only in the key window: a host that sets the cursor
            // itself (a toolbar row while a child window has the key) sets it again now.
            var ancestor = superview
            while let view = ancestor {
                if let host = view as? any ClickableCursorHost {
                    host.clickableStateDidChange(self)
                    return
                }
                ancestor = view.superview
            }
        }
    }

    override open func resetCursorRects() {
        super.resetCursorRects()
        if let hoverCursor, let rect = Self.cursorRect(of: self) { addCursorRect(rect, cursor: hoverCursor) }
    }

    override open func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { cursorTracker.install() }
    }

    override open func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        cursorTracker.viewWillLeave()
    }

    override open func viewDidHide() {
        super.viewDidHide()
        cursorTracker.viewWillLeave()
    }

    /// Where the pointer at `screenPoint` is in `window`'s coordinates, while `window` is the top
    /// window under it (`topWindowNumber`, `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`
    /// outside tests); nil while another window covers that point.
    public static func pointer(in window: NSWindow, screenPoint: NSPoint, topWindowNumber: (NSPoint) -> Int) -> NSPoint? {
        guard topWindowNumber(screenPoint) == window.windowNumber else { return nil }
        return window.convertPoint(fromScreen: screenPoint)
    }

    /// `pointer(in:screenPoint:topWindowNumber:)` for the real pointer and window list.
    public static func currentPointer(in window: NSWindow) -> NSPoint? {
        pointer(in: window, screenPoint: NSEvent.mouseLocation) { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) }
    }

    /// Where a clickable view's cursor rect goes: its visible rect, as `addCursorRect` requires, so
    /// a button clipped by a scroller or a narrow container claims only what shows; nil while the
    /// view is hidden or nothing of it shows.
    public static func cursorRect(of view: NSView) -> NSRect? {
        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
        let rect = view.visibleRect
        return rect.isEmpty ? nil : rect
    }
}

/// The pointing hand over a clickable view while another window of the app has the key (a
/// Chromium page's child window), where its cursor rects do nothing: a tracking area (in the
/// active app, over the visible rect) sets the hand on enter and on every move, and the arrow on
/// exit, on a hide or window change, and on a disable under the pointer; a re-enable under the
/// still pointer sets the hand again. It sets the hand only after reading the pointer again (the
/// view's visible rect, in the top window under the pointer), never over a hidden view, and
/// leaves an exit's arrow out when another view set its own cursor since. In the key window, and
/// inside a `ClickableCursorHost` (the browser toolbar row sets the cursor itself), it sets
/// nothing. The tracking area's owner is this object, so its events never reach the view.
@MainActor
public final class ClickableCursorTracker: NSResponder {
    private weak var view: NSView?
    private let isClickable: () -> Bool
    private var area: NSTrackingArea?
    /// The pointer entered the view and has not left it (no exit, hide or window change since).
    private(set) var inside = false
    /// This tracker set the hand and has not cleared it.
    private(set) var showsHand = false

    // Tests replace these (a test host has no real pointer, key window or window list).
    var isKey: (NSWindow) -> Bool = { $0.isKeyWindow }
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }
    var topWindowNumber: (NSPoint) -> Int = { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) }
    var setCursor: (NSCursor) -> Void = { $0.set() }
    var currentCursor: () -> NSCursor? = { NSCursor.current }

    public init(_ view: NSView, isClickable: @escaping () -> Bool) {
        self.view = view
        self.isClickable = isClickable
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Adds the tracking area once; `.inVisibleRect` keeps it on the view's visible rect.
    public func install() {
        guard area == nil, let view else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        view.addTrackingArea(area)
        self.area = area
    }

    override public func mouseEntered(with event: NSEvent) { pointerEntered() }
    override public func mouseMoved(with event: NSEvent) { pointerMoved() }
    override public func mouseExited(with event: NSEvent) { pointerExited() }

    func pointerEntered() {
        inside = true
        update(readingPointer: true)
    }

    func pointerMoved() {
        guard inside else { return pointerEntered() }
        update(readingPointer: !showsHand)
    }

    func pointerExited() {
        inside = false
        release()
    }

    /// The view was enabled or disabled: under a still pointer the cursor follows at once.
    public func clickableStateDidChange() {
        guard inside else { return }
        update(readingPointer: true)
    }

    /// The view hides or changes window under a still pointer, with no exit event.
    public func viewWillLeave() {
        inside = false
        release()
    }

    private func update(readingPointer: Bool) {
        guard let view, let window = view.window, !isKey(window), !Self.hasHost(view) else { return release() }
        guard isClickable(), !view.isHiddenOrHasHiddenAncestor else { return release() }
        if readingPointer {
            guard let point = ClickableButton.pointer(in: window, screenPoint: mouseLocation(), topWindowNumber: topWindowNumber),
                  view.visibleRect.contains(view.convert(point, from: nil)) else {
                inside = false
                return release()
            }
        }
        showsHand = true
        setCursor(.pointingHand)
    }

    private func release() {
        guard showsHand else { return }
        showsHand = false
        guard currentCursor() === NSCursor.pointingHand, let window = view?.window, !isKey(window) else { return }
        setCursor(.arrow)
    }

    private static func hasHost(_ view: NSView) -> Bool {
        var ancestor = view.superview
        while let current = ancestor {
            if current is any ClickableCursorHost { return true }
            ancestor = current.superview
        }
        return false
    }
}

/// A view that sets the cursor over its clickable subviews itself (on pointer moves), not only
/// through their cursor rects: a `ClickableButton` inside it tells it when it is enabled or
/// disabled, so a still pointer shows the new cursor at once.
@MainActor
public protocol ClickableCursorHost: AnyObject {
    func clickableStateDidChange(_ view: NSView)
}

extension View {
    /// The pointing hand while the pointer is over this view and it is enabled
    /// (`ClickableButton` for SwiftUI). Shared button styles apply it once in `makeBody`.
    public func clickableCursor() -> some View { modifier(ClickableCursorModifier()) }
}

/// `View.clickableCursor()`: `pointerStyle(.link)` on macOS 15 and later. On macOS 14 it pushes
/// the pointing hand while the view is hovered and enabled, and pops it on exit, on disable and
/// when the view goes away mid-hover; a re-enable under a still pointer pushes it again
/// (`ClickableCursorHover`), so a push is always balanced by one pop.
public struct ClickableCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hover = ClickableCursorHover()

    public init() {}

    public func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(isEnabled ? .link : nil)
        } else {
            content
                .onHover { hovering in apply(hover.update(hovering: hovering, enabled: isEnabled)) }
                .onChange(of: isEnabled) { _, enabled in apply(hover.update(hovering: hover.hovering, enabled: enabled)) }
                .onDisappear { apply(hover.update(hovering: false, enabled: isEnabled)) }
        }
    }

    private func apply(_ change: ClickableCursorHover.Change?) {
        switch change {
        case .push: NSCursor.pointingHand.push()
        case .pop: NSCursor.pop()
        case nil: break
        }
    }
}

/// The macOS 14 fallback's cursor stack state: the hand is pushed exactly while the view is
/// hovered and enabled. Each update returns the one push or pop that keeps it so, or nil.
struct ClickableCursorHover: Equatable {
    enum Change: Equatable { case push, pop }

    private(set) var hovering = false
    private(set) var pushed = false

    mutating func update(hovering: Bool, enabled: Bool) -> Change? {
        self.hovering = hovering
        let wanted = hovering && enabled
        guard wanted != pushed else { return nil }
        pushed = wanted
        return wanted ? .push : .pop
    }
}
