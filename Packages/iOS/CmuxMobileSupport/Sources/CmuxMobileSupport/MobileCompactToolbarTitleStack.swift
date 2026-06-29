public import SwiftUI

public enum MobileCompactToolbarTitleMetrics {
    public static let horizontalContentPadding: CGFloat = 3
}

/// Two-line toolbar title text with stable row slots.
///
/// Some glyphs, especially emoji, draw outside the font's nominal line box. In a
/// compact Liquid Glass toolbar control that can make adjacent title/subtitle
/// rows visually touch without changing the measured control height. Clipping
/// each row to its own slot keeps the toolbar height native and prevents tall
/// glyphs from bleeding into the neighboring row.
public struct MobileCompactToolbarTitleStack: View {
    private let title: String
    private let subtitle: String?
    private let titleFont: Font
    private let subtitleFont: Font

    public init(
        title: String,
        subtitle: String?,
        titleFont: Font = .system(size: 14, weight: .semibold),
        subtitleFont: Font = .system(size: 11, weight: .regular)
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleFont = titleFont
        self.subtitleFont = subtitleFont
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            line(title, font: titleFont, height: Metrics.titleRowHeight)

            if let subtitleLine {
                line(subtitleLine, font: subtitleFont, height: Metrics.subtitleRowHeight)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitleLine: String? {
        guard let subtitle, !subtitle.isEmpty else { return nil }
        return subtitle
    }

    private func line(_ text: String, font: Font, height: CGFloat) -> some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: height, alignment: .center)
            .clipped()
    }

    private enum Metrics {
        static let titleRowHeight: CGFloat = 16
        static let subtitleRowHeight: CGFloat = 12
        static let rowSpacing: CGFloat = 1
    }
}
