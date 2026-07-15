import CmuxMobileRPC
import SwiftUI

struct DiffSummaryHeaderView: View {
    let fileCount: Int
    let additions: Int
    let deletions: Int
    let viewedCount: Int
    let baseLabel: String
    let baseKind: MobileDiffBaseKind
    let ignoreWhitespace: Bool
    let selectBase: @MainActor (MobileDiffBaseKind) -> Void
    let setIgnoreWhitespace: @MainActor (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(changedFilesLabel)
                    .font(.headline)
                Spacer()
                Menu {
                    Toggle(isOn: whitespaceBinding) {
                        Label(ignoreWhitespaceLabel, systemImage: "textformat")
                    }
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
            Menu {
                Button(workingTreeLabel) { selectBase(.workingTree) }
                Button(lastTurnLabel) { selectBase(.lastTurn) }
                Button(branchBaseLabel) { selectBase(.branchBase) }
            } label: {
                HStack(spacing: 6) {
                    Text(basePrefix)
                        .foregroundStyle(.secondary)
                    Text(displayedBaseLabel)
                        .fontWeight(.medium)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(basePickerLabel)
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

    private var whitespaceBinding: Binding<Bool> {
        Binding(
            get: { ignoreWhitespace },
            set: { enabled in setIgnoreWhitespace(enabled) }
        )
    }

    private var selectedBaseLabel: String {
        switch baseKind {
        case .workingTree: workingTreeLabel
        case .lastTurn: lastTurnLabel
        case .branchBase: branchBaseLabel
        }
    }

    private var displayedBaseLabel: String {
        guard !baseLabel.isEmpty, baseLabel != selectedBaseLabel else {
            return selectedBaseLabel
        }
        return "\(selectedBaseLabel) · \(baseLabel)"
    }

    private var basePickerLabel: String {
        DiffLocalized().string("diff.base.picker", defaultValue: "Comparison base")
    }

    private var workingTreeLabel: String {
        DiffLocalized().string("diff.base.workingTree", defaultValue: "Working tree")
    }

    private var lastTurnLabel: String {
        DiffLocalized().string("diff.base.lastTurn", defaultValue: "Last agent turn")
    }

    private var branchBaseLabel: String {
        DiffLocalized().string("diff.base.branchBase", defaultValue: "Branch base")
    }

    private var ignoreWhitespaceLabel: String {
        DiffLocalized().string("diff.option.ignoreWhitespace", defaultValue: "Ignore whitespace")
    }
}
