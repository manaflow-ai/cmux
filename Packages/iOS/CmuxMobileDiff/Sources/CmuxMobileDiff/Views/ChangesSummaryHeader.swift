internal import CmuxMobileRPC
internal import Foundation
internal import SwiftUI

struct ChangesSummaryHeader: View {
    let totals: MobileChangesTotals
    let viewedCount: Int
    let ignoresWhitespace: Bool
    let actions: ChangesScreenActions

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(changedFilesText)
                        .font(.headline)
                    Text("+\(totals.additions)")
                        .foregroundStyle(.green)
                    Text("−\(totals.deletions)")
                        .foregroundStyle(.red)
                }
                Text(viewedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                Button {
                } label: {
                    Label(
                        String(localized: "diff.menu.unified", defaultValue: "Unified", bundle: .module),
                        systemImage: "checkmark"
                    )
                }
                Button {
                } label: {
                    Text(String(localized: "diff.menu.splitComingSoon", defaultValue: "Split (coming soon)", bundle: .module))
                }
                .disabled(true)
                Divider()
                Button(action: actions.toggleWhitespace) {
                    Label(
                        String(localized: "diff.menu.ignoreWhitespace", defaultValue: "Ignore whitespace", bundle: .module),
                        systemImage: ignoresWhitespace ? "checkmark" : "circle"
                    )
                }
                Button(
                    String(localized: "diff.menu.collapseAll", defaultValue: "Collapse all", bundle: .module),
                    action: actions.collapseAll
                )
                Button(
                    String(localized: "diff.menu.expandAll", defaultValue: "Expand all", bundle: .module),
                    action: actions.expandAll
                )
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .accessibilityLabel(String(localized: "diff.menu.options", defaultValue: "Diff options", bundle: .module))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var changedFilesText: String {
        let format = String(localized: "diff.summary.changedFiles", defaultValue: "%lld changed files", bundle: .module)
        return String(format: format, locale: .current, totals.files)
    }

    private var viewedText: String {
        let format = String(localized: "diff.summary.viewed", defaultValue: "%lld / %lld viewed", bundle: .module)
        return String(format: format, locale: .current, viewedCount, totals.files)
    }
}
