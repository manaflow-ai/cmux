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
        let oldLines = if hunk.oldCount == 0 {
            L10n.string("mobile.diff.noOldLines", defaultValue: "No old lines")
        } else {
            L10n.string(
                "mobile.diff.oldLineRangeAccessibility",
                defaultValue: "Old lines \(hunk.oldStart) through \(hunk.oldStart + (hunk.oldCount - 1))"
            )
        }
        let newLines = if hunk.newCount == 0 {
            L10n.string("mobile.diff.noNewLines", defaultValue: "No new lines")
        } else {
            L10n.string(
                "mobile.diff.newLineRangeAccessibility",
                defaultValue: "New lines \(hunk.newStart) through \(hunk.newStart + (hunk.newCount - 1))"
            )
        }
        return L10n.string(
            "mobile.diff.hunkAccessibilityFormat",
            defaultValue: "Hunk \(position) of \(total). \(oldLines). \(newLines)"
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
