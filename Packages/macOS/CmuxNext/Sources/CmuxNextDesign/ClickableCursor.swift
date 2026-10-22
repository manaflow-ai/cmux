public import AppKit
public import SwiftUI

/// A button that shows the pointing hand while the pointer is over it and it is enabled, and the
/// arrow while it is disabled (Leo 2026-10-21: "STOP BUTTON, I HOVER OVER IT, MY CURSOR SHOULD
/// ALSO SEE IT AS CLICKABLE"). The shared chrome buttons (toolbar band, pane toolbar, tab bar,
/// sidebar, dialogs, toasts) inherit it, so each says it can be clicked the same way.
///
/// A cursor rect, not a tracking area that sets or pushes the cursor: AppKit owns the rect and
/// drops it when the button hides, leaves its window or scrolls out of view, so no pushed cursor
/// is ever left behind. A change of `isEnabled` rebuilds it at once.
open class ClickableButton: NSButton {
    /// The cursor over a button: the pointing hand while enabled, none (the arrow) while disabled.
    public static func hoverCursor(isEnabled: Bool) -> NSCursor? { isEnabled ? .pointingHand : nil }

    /// This button's cursor now (`hoverCursor(isEnabled:)`).
    public var hoverCursor: NSCursor? { Self.hoverCursor(isEnabled: isEnabled) }

    override open var isEnabled: Bool {
        didSet { if isEnabled != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    override open func resetCursorRects() {
        super.resetCursorRects()
        if let hoverCursor, let rect = Self.cursorRect(of: self) { addCursorRect(rect, cursor: hoverCursor) }
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
