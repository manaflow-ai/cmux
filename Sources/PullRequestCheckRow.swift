import CmuxGit
import Foundation
import SwiftUI

/// An immutable check snapshot rendered below the pull-request panel's `ForEach` boundary.
struct PullRequestCheckRow: View {
    let check: GitHubPullRequestCheck
    let onOpenURL: (URL) -> Void

    var body: some View {
        let row = HStack(spacing: 7) {
            checkIcon
            Text(verbatim: check.name)
                .lineLimit(2)
            Spacer(minLength: 0)
            if check.link != nil {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)

        if let link = check.link {
            Button { onOpenURL(link) } label: { row }
                .buttonStyle(.plain)
                .safeHelp(String(
                    localized: "pullRequestPanel.check.openTooltip",
                    defaultValue: "Open Check"
                ))
        } else {
            row
        }
    }

    @ViewBuilder
    private var checkIcon: some View {
        switch check.presentationState {
        case .pending:
            ProgressView().controlSize(.mini)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .neutral:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }
}
