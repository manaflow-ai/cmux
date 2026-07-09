import Foundation

/// Structured layout of an agent plan string, ready for feed display.
///
/// `PlanBodyView` renders a plan summary by splitting it into headings,
/// paragraphs, numbered lists, and bulleted lists. This value type owns that
/// pure text-to-block parse so the view holds only rendering logic. The block
/// boundaries match the legacy `PlanBodyView.blocks` computed property exactly:
/// blank lines and block-kind transitions flush the current run, `**bold**` /
/// `#` headings / short `Word:` lines become headings, `N. ` lines become
/// numbered items keyed by their printed number, and `- ` / `• ` / `* ` lines
/// become bullets.
public struct WorkstreamPlanLayout: Sendable, Equatable {
    /// A single rendered block in a parsed plan.
    public enum Block: Sendable, Equatable {
        case heading(String)
        case paragraph(String)
        case numbered([NumberedItem])
        case bulleted([String])
    }

    /// One entry of a numbered list, preserving the author's printed number.
    public struct NumberedItem: Sendable, Equatable {
        public let index: Int
        public let text: String

        public init(index: Int, text: String) {
            self.index = index
            self.text = text
        }
    }

    /// The ordered blocks parsed from the plan text.
    public let blocks: [Block]

    /// Parses `plan` into display blocks.
    public init(plan: String) {
        self.blocks = Self.parse(plan)
    }

    private static func parse(_ plan: String) -> [Block] {
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

    private static func markdownHeadingText(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let hashCount = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashCount),
              line.count > hashCount,
              line[line.index(line.startIndex, offsetBy: hashCount)] == " "
        else { return nil }
        return String(line.dropFirst(hashCount + 1))
    }
}
