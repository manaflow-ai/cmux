import AppKit
import CmuxNextDesign
import SwiftUI

/// Palette geometry derived from the shared Design tokens. Every value is
/// computed on read, so it follows `DesignSettings.shared` (density and
/// per-metric overrides) live; nothing here is a hardcoded size.
enum PaletteLayout {
    /// Result rows visible without scrolling. A count, not a size.
    static let visibleRows: CGFloat = 10

    static var width: CGFloat { Metrics.paletteWidth }
    static var searchHeight: CGFloat { Metrics.paletteSearchHeight }
    static var rowHeight: CGFloat { Metrics.paletteRowHeight }
    static var footerHeight: CGFloat { Metrics.paletteRowHeight }
    static var listInset: CGFloat { Metrics.space2 }
    static var listHeight: CGFloat { rowHeight * visibleRows + listInset * 2 }
    static var cornerRadius: CGFloat { Metrics.panelCornerRadius }
    static var rowCornerRadius: CGFloat { Metrics.itemCornerRadius }
    static var height: CGFloat { searchHeight + listHeight + footerHeight + 2 * Metrics.dividerThickness }

    /// Transparent margin around the panel so the shadow and the open
    /// animation are never clipped by the window.
    static var shadowMargin: CGFloat { Metrics.space6 * 2 }
    static var shadowRadius: CGFloat { Metrics.space6 + Metrics.space4 }
    static var shadowOffset: CGFloat { Metrics.space4 }

    static var windowSize: CGSize {
        CGSize(width: width + 2 * shadowMargin, height: height + 2 * shadowMargin)
    }

    static var actionsMenuWidth: CGFloat { width / 2 - Metrics.space6 }
    static var actionsMenuRowHeight: CGFloat { rowHeight - Metrics.space2 }
    static var keycapSize: CGFloat { Metrics.iconSize + Metrics.space2 }
    static var keycapCornerRadius: CGFloat { Metrics.itemCornerRadius - Metrics.space1 }
}

extension Font {
    /// A SwiftUI font from a Design `Typography` token.
    static func token(_ font: NSFont) -> Font {
        Font(font as CTFont)
    }
}

extension Color {
    static func token(_ color: NSColor) -> Color {
        Color(nsColor: color)
    }
}

/// Shortcut badges, one per key, in the Design shortcut face.
struct KeycapsView: View {
    let keycaps: [String]

    var body: some View {
        HStack(spacing: Metrics.space1) {
            ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.token(Typography.shortcut))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: PaletteLayout.keycapSize, minHeight: PaletteLayout.keycapSize)
                    .padding(.horizontal, cap.count > 1 ? Metrics.space2 : 0)
                    .background {
                        RoundedRectangle(cornerRadius: PaletteLayout.keycapCornerRadius, style: .continuous)
                            .fill(Color.token(Palette.hoverFill))
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keycaps.joined())
    }
}
