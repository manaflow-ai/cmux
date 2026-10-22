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
        if let hoverCursor { addCursorRect(bounds, cursor: hoverCursor) }
    }
}

extension View {
    /// The pointing hand while the pointer is over this view and it is enabled
    /// (`ClickableButton` for SwiftUI). Shared button styles apply it once in `makeBody`.
    public func clickableCursor() -> some View { modifier(ClickableCursorModifier()) }
}

/// `View.clickableCursor()`: `pointerStyle(.link)` on macOS 15 and later. On macOS 14 it pushes
/// the pointing hand on hover and pops it on exit, on disable and when the view goes away
/// mid-hover, so a push is always balanced by one pop.
public struct ClickableCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var pushed = false

    public init() {}

    public func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(isEnabled ? .link : nil)
        } else {
            content
                .onHover { setPushed($0 && isEnabled) }
                .onChange(of: isEnabled) { _, enabled in if !enabled { setPushed(false) } }
                .onDisappear { setPushed(false) }
        }
    }

    private func setPushed(_ value: Bool) {
        guard value != pushed else { return }
        pushed = value
        if value { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }
}
