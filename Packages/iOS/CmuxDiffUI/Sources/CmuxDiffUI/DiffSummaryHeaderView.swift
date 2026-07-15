import SwiftUI

struct DiffSummaryHeaderView: View {
    let fileCount: Int
    let additions: Int
    let deletions: Int
    let viewedCount: Int
    let baseLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(changedFilesLabel)
                    .font(.headline)
                Spacer()
                Menu {
                    Button(stubMenuLabel) {}
                        .disabled(true)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel(moreLabel)
            }
            HStack(spacing: 12) {
                Text("+\(additions)")
                    .foregroundStyle(.green)
                Text("−\(deletions)")
                    .foregroundStyle(.red)
                Text(viewedLabel)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.subheadline.monospacedDigit())
            HStack(spacing: 6) {
                Text(basePrefix)
                    .foregroundStyle(.secondary)
                Text(baseLabel)
                    .fontWeight(.medium)
            }
            .font(.caption)
            ProgressView(value: fileCount == 0 ? 0 : Double(viewedCount), total: Double(max(fileCount, 1)))
                .tint(.green)
        }
        .padding(.vertical, 6)
    }

    private var changedFilesLabel: String {
        let localized = DiffLocalized()
        let key: StaticString = fileCount == 1 ? "diff.summary.files.one" : "diff.summary.files.other"
        let value: String.LocalizationValue = fileCount == 1 ? "%lld changed file" : "%lld changed files"
        return localized.format(key, defaultValue: value, Int64(fileCount))
    }

    private var viewedLabel: String {
        DiffLocalized().format(
            "diff.summary.viewed",
            defaultValue: "%lld of %lld viewed",
            Int64(viewedCount),
            Int64(fileCount)
        )
    }

    private var basePrefix: String {
        DiffLocalized().string("diff.summary.base", defaultValue: "Base")
    }

    private var moreLabel: String {
        DiffLocalized().string("diff.action.more", defaultValue: "More options")
    }

    private var stubMenuLabel: String {
        DiffLocalized().string("diff.summary.optionsStub", defaultValue: "Diff options coming next")
    }
}
