import SwiftUI

/// Renders live GitHub content kept in the client detail cache. The feed owner
/// stores only the stable provider references in the item.
struct FeedGitHubDetailSummary: View {
    let detail: GitHubFeedDetail
    @Environment(\.feedColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(detail.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(colors.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail.repository + (detail.number.map { "#\($0)" } ?? ""))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(colors.secondary)
            if let body = detail.body, !body.isEmpty {
                Text(body).font(.system(size: 12)).foregroundStyle(colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let branch = detail.branch, !branch.isEmpty {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11)).foregroundStyle(colors.secondary)
            }
            if !detail.checks.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(detail.checks, id: \.self) { check in
                        Label(check.name + (check.conclusion.map { ": \($0)" } ?? ""),
                              systemImage: check.conclusion == "failure" ? "xmark.circle" : "checkmark.circle")
                            .font(.system(size: 11)).foregroundStyle(check.conclusion == "failure" ? colors.danger : colors.secondary)
                    }
                }
            }
        }
    }
}

struct FeedGitHubActions: View {
    let item: FeedItem
    let model: FeedModel
    @Environment(\.feedColors) private var colors
    @State private var comment = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(FeedStrings.githubActions).font(.system(size: 11, weight: .semibold)).foregroundStyle(colors.secondary)
            HStack(spacing: 7) {
                if supported(.open) { action(FeedStrings.openOnGitHub, "arrow.up.right", .open) }
                if supported(.checkout) { action(FeedStrings.checkout, "arrow.down.to.line", .checkout) }
                if supported(.startAgent) { action(FeedStrings.startAgent, "sparkles", .startAgent) }
                if supported(.approve) { action(FeedStrings.approve, "checkmark", .approve) }
                if supported(.requestChanges) { action(FeedStrings.requestChanges, "exclamationmark.bubble", .requestChanges) }
            }
            if let error = model.githubActionError {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(colors.danger)
            }
            HStack(spacing: 7) {
                TextField(FeedStrings.comment, text: $comment)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                if supported(.comment) {
                    Button(FeedStrings.comment) {
                    let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    model.onGitHubAction?(item, .comment, text)
                    comment = ""
                    }
                    .buttonStyle(FeedButtonStyle(role: .plain, compact: true))
                    .disabled(model.githubActionPending || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(colors.elevated))
    }

    private func supported(_ action: FeedGitHubAction) -> Bool {
        model.githubActions?(item).contains(action) ?? true
    }

    private func action(_ title: String, _ symbol: String, _ kind: FeedGitHubAction) -> some View {
        Button { model.onGitHubAction?(item, kind, nil) } label: {
            Label(title, systemImage: symbol).font(.system(size: 11))
        }
        .buttonStyle(FeedButtonStyle(role: kind == .approve ? .primary : .plain, compact: true))
        .disabled(model.githubActionPending)
    }
}
