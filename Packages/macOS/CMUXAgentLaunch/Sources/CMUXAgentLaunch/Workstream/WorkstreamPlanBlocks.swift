import Foundation

/// A structured parse of an agent's exit-plan text into ordered display
/// blocks. Pure `String -> structured blocks`: it inspects each line of
/// `planText` and groups consecutive lines into headings, paragraphs,
/// numbered lists, and bulleted lists. It performs no rendering and has no
/// app reach, so the Feed plan view can build its layout from `blocks`
/// while this stays a testable value type.
public struct WorkstreamPlanBlocks: Sendable {
    /// One display block in a parsed plan.
    public enum Block: Sendable, Equatable {
        case heading(String)
        case paragraph(String)
        case numbered([NumberedItem])
        case bulleted([String])
    }

    /// A single entry in a numbered list, preserving the author's index so
    /// the rendered list can show the original numbering even when it does
    /// not start at 1 or skips values.
    public struct NumberedItem: Sendable, Equatable {
        public let index: Int
        public let text: String

        public init(index: Int, text: String) {
            self.index = index
            self.text = text
        }
    }

    private let planText: String

    /// Parses `planText` into ordered display blocks.
    public init(planText: String) {
        self.planText = planText
    }

    /// The ordered display blocks parsed from `planText`.
    public var blocks: [Block] {
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

        for rawLine in planText.split(separator: "\n", omittingEmptySubsequences: false) {
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
            if let heading = Self.markdownHeadingText(line) {
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

    /// Extracts the text of an ATX-style markdown heading (`# ` .. `###### `)
    /// from `line`, or returns `nil` when `line` is not such a heading.
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
