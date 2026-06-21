public import CmuxSidebar
public import CoreGraphics
public import SwiftUI

/// Status glyph for a sidebar pull-request row. Picks the open, merged, or
/// closed icon for the given ``SidebarPullRequestStatus`` and scales it by
/// ``fontScale`` to track the sidebar font size.
public struct PullRequestStatusIcon: View {
    let status: SidebarPullRequestStatus
    let color: Color
    var fontScale: CGFloat = 1
    private static let closedFrameSize: CGFloat = 12
    private static let customFrameSize: CGFloat = 13

    /// Creates a pull-request status icon.
    /// - Parameters:
    ///   - status: Lifecycle status that selects the glyph.
    ///   - color: Foreground color applied to the glyph strokes.
    ///   - fontScale: Multiplier applied to the icon frame so it tracks the
    ///     sidebar font size. Defaults to `1`.
    public init(status: SidebarPullRequestStatus, color: Color, fontScale: CGFloat = 1) {
        self.status = status
        self.color = color
        self.fontScale = fontScale
    }

    private var closedFrameSize: CGFloat {
        Self.closedFrameSize * fontScale
    }

    private var customFrameSize: CGFloat {
        Self.customFrameSize * fontScale
    }

    public var body: some View {
        switch status {
        case .open:
            PullRequestOpenIcon(color: color)
                .scaleEffect(fontScale)
                .frame(width: customFrameSize, height: customFrameSize)
        case .merged:
            PullRequestMergedIcon(color: color)
                .scaleEffect(fontScale)
                .frame(width: customFrameSize, height: customFrameSize)
        case .closed:
            Image(systemName: "xmark.circle")
                .font(.system(size: 7 * fontScale, weight: .regular))
                .foregroundColor(color)
                .frame(width: closedFrameSize, height: closedFrameSize)
        }
    }
}
