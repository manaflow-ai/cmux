public import SwiftUI

extension View {
    /// The Liquid Glass button style (`.glass`, macOS 26 and later), or
    /// `.bordered` where Liquid Glass is missing
    /// (`Glass.isLiquidGlassAvailable`), with the pointing hand over it (`clickableCursor()`).
    @ViewBuilder
    public func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *), Glass.isLiquidGlassAvailable {
            buttonStyle(.glass).clickableCursor()
        } else {
            buttonStyle(.bordered).clickableCursor()
        }
    }
}

// The pointing hand for SwiftUI controls lives beside the one style that already imports
// SwiftUI here: macOS UI is AppKit (scripts/cmux-next/check-no-swiftui.py), so a new file must
// not import it. `ClickableButton` is the AppKit side.

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
