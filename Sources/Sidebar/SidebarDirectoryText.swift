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

    /// The full (un-truncated) directory path, used for the hover tooltip.
    /// The first candidate is always the longest form produced by
    /// `SidebarPathFormatter.pathCandidates`.
    private var fullPath: String { candidates.first ?? "" }

    var body: some View {
        Group {
            if candidates.count <= 1 {
                Text(candidates.first ?? "")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                ViewThatFits(in: .horizontal) {
                    ForEach(Array(candidates.dropLast().enumerated()), id: \.offset) { _, candidate in
                        Text(candidate)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(color)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(candidates.last ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .safeHelp(fullPath)
    }
}
