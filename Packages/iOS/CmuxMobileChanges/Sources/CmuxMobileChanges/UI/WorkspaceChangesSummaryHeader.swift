import SwiftUI

struct WorkspaceChangesSummaryHeader: View {
    let branch: String
    let base: String
    let totals: ChangesTotals
    let theme: ChangesTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(filesChangedText)
                    .font(.headline)
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Text(additionsText)
                        .foregroundStyle(theme.addedStatus)
                    Text(deletionsText)
                        .foregroundStyle(theme.deletedStatus)
                }
                .font(.subheadline.monospacedDigit())
            }
            Label(branchBaseText, systemImage: "arrow.triangle.branch")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }

    private var filesChangedText: String {
        String(
            format: String(
                localized: "changes.summary.files_changed",
                defaultValue: "%lld files changed",
                bundle: .module
            ),
            Int64(totals.filesChanged)
        )
    }

    private var additionsText: String {
        String(
            format: String(localized: "changes.summary.additions", defaultValue: "+%lld", bundle: .module),
            Int64(totals.additions)
        )
    }

    private var deletionsText: String {
        String(
            format: String(localized: "changes.summary.deletions", defaultValue: "−%lld", bundle: .module),
            Int64(totals.deletions)
        )
    }

    private var branchBaseText: String {
        String(
            format: String(
                localized: "changes.summary.branch_base",
                defaultValue: "%1$@ ← %2$@",
                bundle: .module
            ),
            branch,
            base
        )
    }
}
