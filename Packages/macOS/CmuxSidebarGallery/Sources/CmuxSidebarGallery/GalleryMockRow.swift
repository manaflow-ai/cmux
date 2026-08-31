import CmuxSidebar
import SwiftUI

/// A stand-in for cmux's AppKit workspace row.
///
/// The real row is an AppKit cell in the app target and cannot be reached from
/// a package. This mirrors its metrics exactly (12.5pt semibold title, 10.5pt
/// details, 8pt leading inset, 6pt corner radius, 8/4 vertical rhythm) so the
/// new chrome is reviewed in a list that lays out like the real one. It is
/// gallery-only and ships nowhere.
struct GalleryMockRow: View {
    let title: String
    let branch: String?
    let directory: String?
    var isActive: Bool = false
    var titleRanges: [Range<Int>] = []
    var branchRanges: [Range<Int>] = []
    var isDimmed: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    private let accent = GalleryCatalog.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            highlighted(title, ranges: titleRanges, size: 12.5, weight: .semibold)
            if let branch {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                        .foregroundStyle(isActive ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary))
                    highlighted(branch, ranges: branchRanges, size: 10.5, weight: .regular)
                        .opacity(isActive ? 1 : 0.72)
                }
            }
            if let directory {
                Text(verbatim: directory)
                    .font(.system(size: 10))
                    .foregroundStyle(isActive ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? accent : .clear)
        )
        .padding(.horizontal, 8)
        .opacity(isDimmed ? 0.35 : 1)
    }

    private func highlighted(
        _ text: String,
        ranges: [Range<Int>],
        size: CGFloat,
        weight: Font.Weight
    ) -> some View {
        let style = SidebarFilterHighlightStyle(
            accent: accent,
            isActiveRow: isActive,
            isDark: colorScheme == .dark
        )
        return Text(style.attributedLabel(displayText: text, ranges: ranges))
            .font(.system(size: size, weight: weight))
    }
}
