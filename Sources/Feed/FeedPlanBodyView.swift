import AppKit
import CMUXAgentLaunch
import CmuxFoundation
import Foundation
import SwiftUI

struct PlanBodyView: View {
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
                                    .cmuxFont(size: 11, weight: .medium, monospacedDigit: true)
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
                .cmuxFont(size: 11, weight: weight ?? .regular)
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var blocks: [FeedPlanBlock] {
        var out: [FeedPlanBlock] = []
        var buffer: [String] = []
        func flushParagraph() {
            guard !buffer.isEmpty else { return }
            let joined = buffer.joined(separator: " ")
            out.append(.paragraph(joined))
            buffer = []
        }
        var numbered: [FeedPlanNumberedItem] = []
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
               && line.split(separator: " ").count <= 4
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
                    numbered.append(FeedPlanNumberedItem(
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
            flushNumbered()
            flushBulleted()
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
