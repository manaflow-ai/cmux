import AppKit
import Bonsplit
import CMUXWorkstream
import SwiftUI

struct ExitPlanActionArea: View {
    let plan: String
    let source: WorkstreamSource
    let status: WorkstreamStatus
    let isRowSelected: Bool
    let onFocusRow: () -> Void
    let onActionRow: () -> Void
    let onBlurRow: () -> Void
    let onApprove: (WorkstreamExitPlanMode, String?) -> Void

    @State private var feedback: String = ""
    @FocusState private var feedbackFocused: Bool

    private var trimmedFeedback: String {
        feedback.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var hasFeedback: Bool { !trimmedFeedback.isEmpty }
    private var preview: WorkstreamExitPlanPreview {
        WorkstreamExitPlanPreview(rawPlan: plan)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlanBodyView(
                plan: preview.planText,
                rendersMarkdown: source == .claude
            )
            if !preview.allowedPrompts.isEmpty {
                ExitPlanAllowedPromptsView(prompts: preview.allowedPrompts)
            }
            if let path = preview.planFilePath {
                ExitPlanPlanFileView(path: path)
            }
            if status.isPending {
                TextField(
                    String(
                        localized: "feed.exitplan.feedback.placeholder",
                        defaultValue: "Tell Claude what to change…"
                    ),
                    text: $feedback,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .tint(Color.primary.opacity(0.75))
                .focused($feedbackFocused)
                .lineLimit(2...5)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(feedbackFocused ? 0.075 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            Color.primary.opacity(feedbackFocused ? 0.20 : (hasFeedback ? 0.25 : 0.10)),
                            lineWidth: 1
                        )
                )
                .onChange(of: feedbackFocused) { _, focused in
                    if focused {
                        onFocusRow()
                    } else {
                        onBlurRow()
                    }
                }
                HStack(spacing: 6) {
                    FeedButton(
                        label: hasFeedback
                            ? String(localized: "feed.exitplan.refine",
                                     defaultValue: "Send feedback")
                            : String(localized: "feed.exitplan.ultraplan",
                                     defaultValue: "Ultraplan"),
                        kind: hasFeedback ? .primary : .soft,
                        size: .medium, fullWidth: true
                    ) {
                        feedbackFocused = false
                        onActionRow()
                        // Feedback always wins over mode; hook translates
                        // non-empty feedback into block+reason.
                        onApprove(hasFeedback ? .manual : .ultraplan, hasFeedback ? trimmedFeedback : nil)
                    }
                    FeedButton(
                        label: String(localized: "feed.exitplan.manual",
                                      defaultValue: "Manual"),
                        kind: .soft,
                        size: .medium, fullWidth: true,
                        dimmed: hasFeedback
                    ) {
                        feedbackFocused = false
                        onActionRow()
                        onApprove(.manual, hasFeedback ? trimmedFeedback : nil)
                    }
                    FeedButton(
                        label: String(localized: "feed.exitplan.auto",
                                      defaultValue: "Auto"),
                        kind: .success,
                        size: .medium, fullWidth: true,
                        dimmed: hasFeedback
                    ) {
                        feedbackFocused = false
                        onActionRow()
                        onApprove(.autoAccept, hasFeedback ? trimmedFeedback : nil)
                    }
                }
            } else if let badge = submittedBadge {
                FeedButton(
                    label: badge,
                    leadingIcon: "checkmark",
                    kind: .success,
                    size: .medium,
                    fullWidth: true,
                    dimmed: true
                ) {}
            }
        }
        .onChange(of: isRowSelected) { _, selected in
            if !selected {
                feedbackFocused = false
            }
        }
    }

    private var submittedBadge: String? {
        guard case .resolved(let decision, _) = status else { return nil }
        let submitted = String(localized: "feed.badge.submitted", defaultValue: "Submitted")
        switch decision {
        case .exitPlan(let mode, let feedback):
            if let feedback, !feedback.isEmpty {
                return "\(submitted) · " + String(
                    localized: "feed.badge.refined", defaultValue: "refined"
                )
            }
            return "\(submitted) · \(mode.displayLabel)"
        default:
            return submitted
        }
    }
}

private struct ExitPlanAllowedPromptsView: View {
    let prompts: [WorkstreamAllowedPrompt]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.purple.opacity(0.85))
                Text(String(localized: "feed.exitplan.allowedPrompts", defaultValue: "Allowed prompts"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.purple.opacity(0.9))
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(prompts.enumerated()), id: \.offset) { _, prompt in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if !prompt.tool.isEmpty {
                            Text(prompt.tool)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.purple.opacity(0.14))
                                )
                        }
                        Text(prompt.prompt)
                            .font(.system(size: 11))
                            .foregroundColor(.primary.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.purple.opacity(0.06))
            )
        }
    }
}

private struct ExitPlanPlanFileView: View {
    let path: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(String(localized: "feed.exitplan.planFile", defaultValue: "Plan file"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
        }
    }
}

struct FeedMarkdownInlineText: View {
    let text: String
    let fontSize: CGFloat
    let weight: Font.Weight?
    let foregroundColor: Color

    init(
        text: String,
        fontSize: CGFloat,
        weight: Font.Weight? = nil,
        foregroundColor: Color
    ) {
        self.text = text
        self.fontSize = fontSize
        self.weight = weight
        self.foregroundColor = foregroundColor
    }

    var body: some View {
        let parsed = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
        let font = weight.map { Font.system(size: fontSize, weight: $0) }
            ?? Font.system(size: fontSize)
        Text(parsed)
            .font(font)
            .foregroundColor(foregroundColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Renders plan text as a stack of small structured sections. Block
/// headings, lists, and paragraphs keep the Feed's compact rhythm, while
/// Claude markdown inside each line gets parsed tastefully. Heading text
/// intentionally stays at body scale.
private struct PlanBodyView: View {
    let plan: String
    let rendersMarkdown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    markdownText(
                        text,
                        weight: .semibold,
                        color: .primary.opacity(0.95)
                    )
                        .padding(.top, 2)
                case .paragraph(let text):
                    markdownText(text, color: .primary.opacity(0.85))
                case .numbered(let items):
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 5) {
                                Text("\(item.index).")
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundColor(.secondary)
                                markdownText(item.text, color: .primary.opacity(0.85))
                            }
                        }
                    }
                case .bulleted(let items):
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(Color.blue.opacity(0.85))
                                    .frame(width: 3.5, height: 3.5)
                                    .padding(.top, 5.5)
                                    .frame(width: 10, alignment: .center)
                                markdownText(item, color: .primary.opacity(0.85))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func markdownText(
        _ text: String,
        weight: Font.Weight? = nil,
        color: Color
    ) -> some View {
        if rendersMarkdown {
            FeedMarkdownInlineText(
                text: text,
                fontSize: 11,
                weight: weight,
                foregroundColor: color
            )
        } else {
            Text(text)
                .font(.system(size: 11, weight: weight ?? .regular))
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private enum Block {
        case heading(String)
        case paragraph(String)
        case numbered([NumberedItem])
        case bulleted([String])
    }

    private struct NumberedItem {
        let index: Int
        let text: String
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var buffer: [String] = []
        func flushParagraph() {
            guard !buffer.isEmpty else { return }
            let joined = buffer.joined(separator: " ")
            out.append(.paragraph(joined))
            buffer = []
        }
        var numbered: [NumberedItem] = []
        func flushNumbered() {
            if !numbered.isEmpty {
                out.append(.numbered(numbered))
                numbered = []
            }
        }
        var bulleted: [String] = []
        func flushBulleted() {
            if !bulleted.isEmpty {
                out.append(.bulleted(bulleted))
                bulleted = []
            }
        }

        for rawLine in plan.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph(); flushNumbered(); flushBulleted()
                continue
            }
            // **Bold heading** or ## heading or "Word:" on its own line
            if line.hasPrefix("**") && line.hasSuffix("**") && line.count > 4 {
                flushParagraph(); flushNumbered(); flushBulleted()
                out.append(.heading(String(line.dropFirst(2).dropLast(2))))
                continue
            }
            if let heading = markdownHeadingText(line) {
                flushParagraph(); flushNumbered(); flushBulleted()
                out.append(.heading(heading))
                continue
            }
            if line.hasSuffix(":") && line.count <= 40
               && !line.contains(" ") == false && line.split(separator: " ").count <= 4
            {
                flushParagraph(); flushNumbered(); flushBulleted()
                out.append(.heading(line))
                continue
            }
            // Numbered list
            if let match = line.range(
                of: #"^(\d+)\.\s+(.+)$"#,
                options: .regularExpression
            ) {
                flushParagraph(); flushBulleted()
                let text = String(line[match])
                if let dotIdx = text.firstIndex(of: ".") {
                    let numStr = String(text[text.startIndex..<dotIdx])
                    let content = String(text[text.index(after: dotIdx)...])
                        .trimmingCharacters(in: .whitespaces)
                    numbered.append(NumberedItem(
                        index: Int(numStr) ?? (numbered.count + 1),
                        text: content
                    ))
                }
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") {
                flushParagraph(); flushNumbered()
                let text = String(line.dropFirst(2))
                bulleted.append(text)
                continue
            }
            buffer.append(line)
        }
        flushParagraph(); flushNumbered(); flushBulleted()
        return out
    }

    private func markdownHeadingText(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let hashCount = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashCount),
              line.count > hashCount,
              line[line.index(line.startIndex, offsetBy: hashCount)] == " "
        else { return nil }
        return String(line.dropFirst(hashCount + 1))
    }
}

extension WorkstreamExitPlanMode {
    var displayLabel: String {
        switch self {
        case .ultraplan:
            return String(localized: "feed.exitplan.mode.ultraplan", defaultValue: "ultraplan")
        case .bypassPermissions:
            return String(localized: "feed.exitplan.mode.bypass", defaultValue: "bypass")
        case .autoAccept:
            return String(localized: "feed.exitplan.mode.autoAccept", defaultValue: "auto")
        case .manual:
            return String(localized: "feed.exitplan.mode.manual", defaultValue: "manual")
        case .deny:
            return String(localized: "feed.exitplan.mode.deny", defaultValue: "denied")
        }
    }
}
