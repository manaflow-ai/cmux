#if canImport(UIKit)
import CmuxMobileSupport
import Foundation
import SwiftUI

struct MobileDiffNavigationBar: View {
    let selectedFile: MobileDiffFile?
    let fileCount: Int
    let canSelectPrevious: Bool
    let canSelectNext: Bool
    let showFiles: () -> Void
    let selectPrevious: () -> Void
    let selectNext: () -> Void
    let reload: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: showFiles) {
                HStack(spacing: 7) {
                    Image(systemName: "list.bullet")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selectedFile?.name ?? L10n.string("mobile.diff.files", defaultValue: "Changed Files"))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(fileCountLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("MobileDiffFileListButton")

            Button(action: selectPrevious) { Image(systemName: "chevron.up") }
                .disabled(!canSelectPrevious)
                .accessibilityLabel(L10n.string("mobile.diff.previousFile", defaultValue: "Previous File"))
            Button(action: selectNext) { Image(systemName: "chevron.down") }
                .disabled(!canSelectNext)
                .accessibilityLabel(L10n.string("mobile.diff.nextFile", defaultValue: "Next File"))
            Button(action: reload) { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel(L10n.string("mobile.diff.refresh", defaultValue: "Refresh Diff"))
            Button(action: close) { Image(systemName: "xmark") }
                .accessibilityLabel(L10n.string("mobile.diff.close", defaultValue: "Close Diff"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var fileCountLabel: String {
        if fileCount == 1 {
            return L10n.string("mobile.diff.fileCount.one", defaultValue: "1 file")
        }
        return String(
            format: L10n.string("mobile.diff.fileCount.other", defaultValue: "%lld files"),
            locale: Locale.current,
            fileCount
        )
    }
}
#endif
