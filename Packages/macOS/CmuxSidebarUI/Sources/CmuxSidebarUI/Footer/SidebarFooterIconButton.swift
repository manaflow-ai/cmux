public import CoreGraphics
public import SwiftUI
private import CmuxAppKitSupportUI

/// A styled icon button for the sidebar footer (help, extensions, etc.).
///
/// Draws a monochrome SF Symbol centered in a fixed square hit target, wrapped
/// in the shared ``SidebarFooterIconButtonStyle`` rounded hover/press highlight.
/// The symbol, sizes, and the press action are supplied by the caller, so this
/// package view holds no app-target dependency.
///
/// This view intentionally carries no tooltip or accessibility metadata: the
/// footer buttons differ in how they compose popover anchors, accessibility
/// elements, and help text around the styled button, so each call site applies
/// those modifiers itself in its own order. The button's frame is reserved at
/// `buttonSize × buttonSize`; the symbol is rasterized at `iconSize` so callers
/// can tune the glyph independently of the hit target.
public struct SidebarFooterIconButton: View {
    let systemImage: String
    let iconSize: CGFloat
    let buttonSize: CGFloat
    let action: () -> Void

    /// Creates a styled sidebar footer icon button.
    /// - Parameters:
    ///   - systemImage: SF Symbol name for the glyph.
    ///   - iconSize: Point size the symbol is rasterized at.
    ///   - buttonSize: Width and height of the square hit target.
    ///   - action: Invoked when the button is pressed.
    public init(
        systemImage: String,
        iconSize: CGFloat,
        buttonSize: CGFloat,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.iconSize = iconSize
        self.buttonSize = buttonSize
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .cmuxSymbolRasterSize(iconSize, weight: .medium)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: buttonSize, height: buttonSize, alignment: .center)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
    }
}
