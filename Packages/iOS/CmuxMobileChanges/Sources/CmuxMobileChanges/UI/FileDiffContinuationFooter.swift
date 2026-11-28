internal import Foundation
internal import SwiftUI

struct FileDiffContinuationFooter: View {
    let continuation: FileDiffContinuation
    let state: FileDiffContinuationLoadState
    let onShowMore: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if continuation.canShowMore {
                Text(progressText)
                .font(.footnote)
                .foregroundStyle(.secondary)

                Button(action: onShowMore) {
                    HStack(spacing: 8) {
                        if state == .loading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(String(
                            localized: "changes.diff.show_more",
                            defaultValue: "Show more",
                            bundle: .module
                        ))
                    }
                }
                .disabled(state == .loading)

                if state == .failed {
                    Text(String(
                        localized: "changes.diff.show_more_failed",
                        defaultValue: "Couldn't load more diff lines. Try again.",
                        bundle: .module
                    ))
                    .font(.footnote)
                    .foregroundStyle(.red)
                }
            } else {
                Text(String(
                    format: String(
                        localized: "changes.diff.truncated",
                        defaultValue: "Large diff. Showing the first %lld lines to keep things fast. See the rest on your Mac.",
                        bundle: .module
                    ),
                    Int64(continuation.shownLineCount)
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    private var progressText: String {
        if let totalLineCount = continuation.totalLineCount {
            return String(
                format: String(
                    localized: "changes.diff.progress",
                    defaultValue: "Showing %1$@ of %2$@ diff lines",
                    bundle: .module
                ),
                continuation.shownLineCount.formatted(),
                totalLineCount.formatted()
            )
        }
        return String(
            format: String(
                localized: "changes.diff.progress_loaded_only",
                defaultValue: "Showing the first %@ diff lines",
                bundle: .module
            ),
            continuation.shownLineCount.formatted()
        )
    }
}
