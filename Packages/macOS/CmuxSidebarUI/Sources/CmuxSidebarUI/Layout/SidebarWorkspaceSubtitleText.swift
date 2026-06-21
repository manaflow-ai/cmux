public import CoreGraphics
public import SwiftUI

/// The single-line subtitle shown under a workspace title.
///
/// Carries either the latest notification text or the latest conversation
/// message, whichever the owning row resolved as the effective subtitle. Wraps
/// to at most two lines and tail-truncates. The caller resolves the color from
/// the active/inverted foreground ramp and passes it in, so this package view
/// carries no app-target color dependency.
public struct SidebarWorkspaceSubtitleText: View {
    let text: String
    let color: Color
    let fontScale: CGFloat

    /// Creates the subtitle text.
    /// - Parameters:
    ///   - text: The resolved subtitle string to display.
    ///   - color: Foreground color for the subtitle.
    ///   - fontScale: Multiplier applied to the subtitle font size.
    public init(text: String, color: Color, fontScale: CGFloat) {
        self.text = text
        self.color = color
        self.fontScale = fontScale
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 10 * fontScale))
            .foregroundColor(color)
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
    }
}
