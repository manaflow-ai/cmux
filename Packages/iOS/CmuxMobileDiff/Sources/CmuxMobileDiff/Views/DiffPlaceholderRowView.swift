internal import Foundation
internal import SwiftUI

struct DiffPlaceholderRowView: View {
    let file: DiffFileSnapshot
    let row: DiffRowSnapshot
    let retry: @MainActor @Sendable (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch row.kind {
            case .binary:
                Image(systemName: "doc.badge.ellipsis")
                Text(String(localized: "diff.file.binary", defaultValue: "Binary file not shown", bundle: .module))
            case .largeDiff:
                if file.isLoading {
                    ProgressView()
                    Text(loadingPagesText)
                } else {
                    Button {
                        retry(file.path)
                    } label: {
                        Label(String(localized: "diff.file.load", defaultValue: "Load diff", bundle: .module), systemImage: "arrow.down.doc")
                    }
                }
            case .renameOnly:
                Image(systemName: "arrow.right")
                Text(String(localized: "diff.file.renameOnly", defaultValue: "File renamed without content changes", bundle: .module))
            case .tooLarge:
                Image(systemName: "exclamationmark.doc")
                Text(String(localized: "diff.file.tooLarge", defaultValue: "Diff is too large to display", bundle: .module))
            case .loading:
                ProgressView()
                Text(String(localized: "diff.file.loading", defaultValue: "Loading diff…", bundle: .module))
            case .error:
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(file.errorMessage ?? String(localized: "diff.error.file", defaultValue: "Couldn’t load this file. Try again.", bundle: .module))
                Spacer()
                Button(String(localized: "diff.action.retry", defaultValue: "Retry", bundle: .module)) {
                    retry(file.path)
                }
            default:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
    }

    private var loadingPagesText: String {
        let format = String(localized: "diff.file.loadingPages", defaultValue: "Loading page %lld…", bundle: .module)
        return String(format: format, locale: .current, max(1, file.loadedPageCount + 1))
    }
}
