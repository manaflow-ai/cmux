import CmuxDiffModel
import CmuxMobileSupport
import SwiftUI

struct DiffReviewHunkView: View {
    static let maxRenderedLines = 2000

    let hunk: DiffHunk
    let position: Int
    let total: Int
    let moveBackward: () -> Void
    let moveForward: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: hunk.header)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(.thinMaterial)
                .contentShape(.rect)
                .gesture(hunkSwipeGesture)
                .accessibilityLabel(hunkAccessibilityLabel)
                .accessibilityHint(
                    L10n.string(
                        "mobile.diff.hunkSwipeHint",
                        defaultValue: "Swipe left or right here to move between hunks"
                    )
                )

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hunk.lines.prefix(Self.maxRenderedLines)) { line in
                        DiffReviewLineView(line: line)
                    }
                    if hunk.lines.count > Self.maxRenderedLines {
                        Label(
                            String(
                                format: L10n.string(
                                    "mobile.diff.hunkLinesTruncated",
                                    defaultValue: "Showing first %1$d of %2$d lines"
                                ),
                                Self.maxRenderedLines,
                                hunk.lines.count
                            ),
                            systemImage: "scissors"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                    }
                }
            }
        }
    }

    private var hunkAccessibilityLabel: String {
        String(
            format: L10n.string(
                "mobile.diff.hunkAccessibilityFormat",
                defaultValue: "Hunk %1$d of %2$d. Old lines %3$d through %4$d. New lines %5$d through %6$d"
            ),
            position,
            total,
            hunk.oldStart,
            max(hunk.oldStart, hunk.oldStart + hunk.oldCount - 1),
            hunk.newStart,
            max(hunk.newStart, hunk.newStart + hunk.newCount - 1)
        )
    }

    private var hunkSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 36)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) >= 80, abs(horizontal) > abs(vertical) * 1.5 else { return }
                if horizontal < 0 {
                    moveForward()
                } else {
                    moveBackward()
                }
            }
    }
}
