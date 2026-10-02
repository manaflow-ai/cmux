import SwiftUI

/// What a request asks, above its controls: the command, the diff, the
/// origin, the statement. `full` shows everything (inbox detail).
struct FeedPromptSummary: View {
    let item: FeedItem
    var full = false
    @Environment(\.feedColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !item.body.isEmpty && (full || item.isRequest) {
                Text(item.body)
                    .font(.system(size: 12))
                    .foregroundStyle(colors.secondary)
                    .lineLimit(full ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            prompt
            if let diff = item.diffAttachment {
                FeedDiffPreview(attachment: diff, maxLines: full ? nil : 6)
            }
        }
    }

    @ViewBuilder
    private var prompt: some View {
        switch item.prompt {
        case let .approve(approve):
            if let command = approve.action.command {
                FeedCodeBlock(text: command, caption: approve.action.cwd)
            }
        case let .question(question):
            text(question.question)
        case let .confirm(confirm):
            text(confirm.statement)
        case let .signIn(signIn):
            origin(signIn.origin, signIn.reason)
        case let .passkey(passkey):
            origin(passkey.rpID ?? passkey.origin, passkey.reason)
        case let .review(review):
            if full && !review.checklist.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(review.checklist, id: \.self) { line in
                        Label(line, systemImage: "circle").font(.system(size: 11.5)).foregroundStyle(colors.secondary)
                    }
                }
            }
        case let .handoff(handoff):
            if let hint = handoff.resumeHint, full { text(hint) }
        case let .file(file):
            text(file.purpose)
        case .notice, .choice, .input, .custom:
            EmptyView()
        }
    }

    private func text(_ value: String) -> some View {
        Text(value).font(.system(size: 12.5)).foregroundStyle(colors.primary).fixedSize(horizontal: false, vertical: true)
    }

    private func origin(_ host: String, _ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(host.replacingOccurrences(of: "https://", with: ""), systemImage: "lock")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(colors.primary)
            Text(reason).font(.system(size: 12)).foregroundStyle(colors.secondary)
        }
    }
}

/// A command in a faint monospaced block, with its working directory.
struct FeedCodeBlock: View {
    let text: String
    var caption: String?
    @Environment(\.feedColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(colors.primary)
                .textSelection(.enabled)
            if let caption {
                Text(caption).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(colors.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(colors.hover))
    }
}

/// A plain unified diff: added lines green, removed lines red, hunks dim.
struct FeedDiffPreview: View {
    let attachment: FeedAttachment
    var maxLines: Int?
    @Environment(\.feedColors) private var colors

    var body: some View {
        let lines = (attachment.text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let shown = maxLines.map { Array(lines.prefix($0)) } ?? lines
        VStack(alignment: .leading, spacing: 0) {
            Label(attachment.name, systemImage: "doc.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(colors.secondary)
                .padding(.horizontal, 9).padding(.vertical, 6)
            FeedHairline()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(line))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .background(fill(line))
                }
                if shown.count < lines.count {
                    Text(verbatim: "…").font(.system(size: 11, design: .monospaced)).foregroundStyle(colors.tertiary).padding(.horizontal, 9)
                }
            }
            .padding(.vertical, 5)
            .textSelection(.enabled)
        }
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(colors.hover.opacity(0.6)))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func color(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return colors.tertiary }
        if line.hasPrefix("@@") { return colors.tertiary }
        if line.hasPrefix("+") { return colors.success }
        if line.hasPrefix("-") { return colors.danger }
        return colors.secondary
    }

    private func fill(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return colors.success.opacity(0.08) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return colors.danger.opacity(0.08) }
        return .clear
    }
}
