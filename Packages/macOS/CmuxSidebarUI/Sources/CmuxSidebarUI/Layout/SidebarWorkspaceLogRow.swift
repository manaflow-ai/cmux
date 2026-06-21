public import CmuxSidebar
public import CoreGraphics
public import SwiftUI

/// The latest-log line shown under a workspace row.
///
/// Renders a level glyph and the log message. The level-to-icon and
/// level-to-color mappings live here; when the row is active the color is
/// derived from the caller's inverted-foreground ramp via
/// ``activeSecondaryColor``, otherwise it uses the fixed per-level colors.
public struct SidebarWorkspaceLogRow: View {
    let entry: SidebarLogEntry
    let isActive: Bool
    let activeSecondaryColor: (Double) -> Color
    let messageColor: Color
    let fontScale: CGFloat

    /// Creates the latest-log row.
    /// - Parameters:
    ///   - entry: The log entry to render.
    ///   - isActive: Whether the owning workspace row is active.
    ///   - activeSecondaryColor: Maps an opacity to the inverted-foreground
    ///     color used for the level glyph when active.
    ///   - messageColor: Foreground color for the message text.
    ///   - fontScale: Multiplier applied to base font sizes.
    public init(
        entry: SidebarLogEntry,
        isActive: Bool,
        activeSecondaryColor: @escaping (Double) -> Color,
        messageColor: Color,
        fontScale: CGFloat
    ) {
        self.entry = entry
        self.isActive = isActive
        self.activeSecondaryColor = activeSecondaryColor
        self.messageColor = messageColor
        self.fontScale = fontScale
    }

    private func scaledFontSize(_ baseSize: CGFloat) -> CGFloat {
        baseSize * fontScale
    }

    private var levelIcon: String {
        switch entry.level {
        case .info: return "circle.fill"
        case .progress: return "arrowtriangle.right.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private var levelColor: Color {
        if isActive {
            switch entry.level {
            case .info:
                return activeSecondaryColor(0.5)
            case .progress:
                return activeSecondaryColor(0.8)
            case .success:
                return activeSecondaryColor(0.9)
            case .warning:
                return activeSecondaryColor(0.9)
            case .error:
                return activeSecondaryColor(0.9)
            }
        }
        switch entry.level {
        case .info: return .secondary
        case .progress: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: levelIcon)
                .font(.system(size: scaledFontSize(8)))
                .foregroundColor(levelColor)
            Text(entry.message)
                .font(.system(size: scaledFontSize(10)))
                .foregroundColor(messageColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
