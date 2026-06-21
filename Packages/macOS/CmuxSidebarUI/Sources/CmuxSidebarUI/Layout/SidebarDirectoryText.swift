public import CoreGraphics
public import SwiftUI

/// Renders a workspace directory path in the sidebar, choosing the longest
/// candidate that fits the available width.
///
/// Non-fallback candidates use `.fixedSize(horizontal: true)` so a candidate
/// that would only fit by truncating reports its full intrinsic width to
/// `ViewThatFits` and gets skipped in favor of the next, shorter form. The
/// final fallback keeps `.truncationMode(.tail)` for the rare case where even
/// `…/<lastSegment>` overflows.
public struct SidebarDirectoryText: View {
    let candidates: [String]
    let color: Color
    var fontScale: CGFloat = 1

    /// Creates a directory text view.
    /// - Parameters:
    ///   - candidates: Directory display strings ordered longest to shortest;
    ///     the widest one that fits is shown.
    ///   - color: Foreground color for the directory text.
    ///   - fontScale: Multiplier applied to the base font size. Defaults to `1`.
    public init(candidates: [String], color: Color, fontScale: CGFloat = 1) {
        self.candidates = candidates
        self.color = color
        self.fontScale = fontScale
    }

    public var body: some View {
        if candidates.count <= 1 {
            Text(candidates.first ?? "")
                .font(.system(size: 10 * fontScale, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach(Array(candidates.dropLast().enumerated()), id: \.offset) { _, candidate in
                    Text(candidate)
                        .font(.system(size: 10 * fontScale, design: .monospaced))
                        .foregroundColor(color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text(candidates.last ?? "")
                    .font(.system(size: 10 * fontScale, design: .monospaced))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}
