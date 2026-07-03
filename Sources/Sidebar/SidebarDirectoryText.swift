import CmuxFoundation
import SwiftUI

// Picks the longest directory candidate that fits the available width.
// Non-fallback candidates use `.fixedSize(horizontal: true)` so a candidate
// that would only fit by truncating reports its full intrinsic width to
// `ViewThatFits` and gets skipped in favor of the next, shorter form. The
// final fallback keeps `.truncationMode(.tail)` for the rare case where even
// `…/<lastSegment>` overflows.
struct SidebarDirectoryText: View {
    let candidates: [String]
    let color: Color
    var fontScale: CGFloat = 1

    var body: some View {
        if candidates.count <= 1 {
            Text(candidates.first ?? "")
                .cmuxFont(size: 10 * fontScale)
                .foregroundColor(color)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach(Array(candidates.dropLast().enumerated()), id: \.offset) { _, candidate in
                    Text(candidate)
                        .cmuxFont(size: 10 * fontScale)
                        .foregroundColor(color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text(candidates.last ?? "")
                    .cmuxFont(size: 10 * fontScale)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}
