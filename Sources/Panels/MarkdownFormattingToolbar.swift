import AppKit
import SwiftUI

/// A markdown formatting action the editor toolbar can apply. All the string
/// work lives in pure helpers so behavior is unit-testable without AppKit.
enum MarkdownFormatAction: CaseIterable {
    case heading1
    case heading2
    case heading3
    case bold
    case italic
    case strikethrough
    case bulletList
    case numberedList
    case taskList
    case quote
    case link

    var systemImage: String {
        switch self {
        case .heading1: return "1.square"
        case .heading2: return "2.square"
        case .heading3: return "3.square"
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .bulletList: return "list.bullet"
        case .numberedList: return "list.number"
        case .taskList: return "checklist"
        case .quote: return "text.quote"
        case .link: return "link"
        }
    }

    var label: String {
        switch self {
        case .heading1:
            return String(localized: "markdown.format.heading1", defaultValue: "Heading 1")
        case .heading2:
            return String(localized: "markdown.format.heading2", defaultValue: "Heading 2")
        case .heading3:
            return String(localized: "markdown.format.heading3", defaultValue: "Heading 3")
        case .bold:
            return String(localized: "markdown.format.bold", defaultValue: "Bold")
        case .italic:
            return String(localized: "markdown.format.italic", defaultValue: "Italic")
        case .strikethrough:
            return String(localized: "markdown.format.strikethrough", defaultValue: "Strikethrough")
        case .bulletList:
            return String(localized: "markdown.format.bulletList", defaultValue: "Bulleted List")
        case .numberedList:
            return String(localized: "markdown.format.numberedList", defaultValue: "Numbered List")
        case .taskList:
            return String(localized: "markdown.format.taskList", defaultValue: "Task List")
        case .quote:
            return String(localized: "markdown.format.quote", defaultValue: "Quote")
        case .link:
            return String(localized: "markdown.format.link", defaultValue: "Link")
        }
    }
}

/// Pure markdown edits: given the current text and selection, produce the
/// replacement string, the range it replaces, and where the selection should
/// land. Kept free of AppKit so `cmuxTests` can pin the behavior.
enum MarkdownFormatter {
    struct Edit: Equatable {
        /// UTF-16 range in the original text that `replacement` replaces.
        var range: NSRange
        var replacement: String
        /// Desired selection after the edit, in post-edit UTF-16 coordinates.
        var selection: NSRange
    }

    static func edit(for action: MarkdownFormatAction, in text: String, selection: NSRange) -> Edit {
        switch action {
        case .bold: return wrap(text, selection, marker: "**")
        case .italic: return wrap(text, selection, marker: "*")
        case .strikethrough: return wrap(text, selection, marker: "~~")
        case .heading1: return prefixLines(text, selection, prefix: "# ", replacingHeading: true)
        case .heading2: return prefixLines(text, selection, prefix: "## ", replacingHeading: true)
        case .heading3: return prefixLines(text, selection, prefix: "### ", replacingHeading: true)
        case .bulletList: return prefixLines(text, selection, prefix: "- ")
        case .numberedList: return numberLines(text, selection)
        case .taskList: return prefixLines(text, selection, prefix: "- [ ] ")
        case .quote: return prefixLines(text, selection, prefix: "> ")
        case .link: return link(text, selection)
        }
    }

    /// Wrap the selection in `marker`; with no selection, insert a pair and
    /// park the caret between them.
    private static func wrap(_ text: String, _ selection: NSRange, marker: String) -> Edit {
        let ns = text as NSString
        let selected = selection.length > 0 ? ns.substring(with: selection) : ""
        let replacement = marker + selected + marker
        let markerLength = (marker as NSString).length
        return Edit(
            range: selection,
            replacement: replacement,
            selection: NSRange(location: selection.location + markerLength, length: selection.length)
        )
    }

    /// Prefix every line touched by the selection. For headings, an existing
    /// `#{1,6} ` prefix is replaced instead of stacked.
    private static func prefixLines(
        _ text: String, _ selection: NSRange, prefix: String, replacingHeading: Bool = false
    ) -> Edit {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: selection)
        let block = ns.substring(with: lineRange)
        let trailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if trailingNewline { lines.removeLast() }

        let rewritten = lines.map { line -> String in
            var body = line
            if replacingHeading {
                body = stripHeadingPrefix(line)
                if line == prefix + body {
                    // Toggling the same heading level off restores plain text.
                    return body
                }
            }
            return prefix + body
        }
        var replacement = rewritten.joined(separator: "\n")
        if trailingNewline { replacement += "\n" }
        return Edit(
            range: lineRange,
            replacement: replacement,
            selection: NSRange(location: lineRange.location + (replacement as NSString).length, length: 0)
        )
    }

    private static func numberLines(_ text: String, _ selection: NSRange) -> Edit {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: selection)
        let block = ns.substring(with: lineRange)
        let trailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if trailingNewline { lines.removeLast() }

        let rewritten = lines.enumerated().map { "\($0.offset + 1). \($0.element)" }
        var replacement = rewritten.joined(separator: "\n")
        if trailingNewline { replacement += "\n" }
        return Edit(
            range: lineRange,
            replacement: replacement,
            selection: NSRange(location: lineRange.location + (replacement as NSString).length, length: 0)
        )
    }

    private static func link(_ text: String, _ selection: NSRange) -> Edit {
        let ns = text as NSString
        let selected = selection.length > 0 ? ns.substring(with: selection) : ""
        let urlPlaceholder = "url"
        let replacement = "[\(selected)](\(urlPlaceholder))"
        let selectionStart: Int
        if selection.length > 0 {
            // Select the placeholder URL so typing replaces it.
            selectionStart = selection.location + ("[\(selected)](" as NSString).length
            return Edit(
                range: selection,
                replacement: replacement,
                selection: NSRange(location: selectionStart, length: (urlPlaceholder as NSString).length)
            )
        }
        // No selection: select the empty link text first.
        return Edit(
            range: selection,
            replacement: replacement,
            selection: NSRange(location: selection.location + 1, length: 0)
        )
    }

    private static func stripHeadingPrefix(_ line: String) -> String {
        var index = line.startIndex
        var hashes = 0
        while index < line.endIndex, line[index] == "#", hashes < 6 {
            hashes += 1
            index = line.index(after: index)
        }
        guard hashes > 0, index < line.endIndex, line[index] == " " else { return line }
        return String(line[line.index(after: index)...])
    }
}

/// The formatting strip shown above the source editor — the reference design's
/// H1/H2/H3 · B/I/S · lists · quote/link row, applying markdown syntax at the
/// editor's selection with full undo support.
struct MarkdownFormattingToolbar: View {
    @ObservedObject var panel: MarkdownPanel

    private static let groups: [[MarkdownFormatAction]] = [
        [.heading1, .heading2, .heading3],
        [.bold, .italic, .strikethrough],
        [.bulletList, .numberedList, .taskList],
        [.quote, .link],
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    // A fixed-size rectangle, not Divider: unbounded height
                    // proposals during split relayout have made 1px chrome in
                    // this pane paint far outside its row (the phantom
                    // vertical-line family), and a hard 1×14 frame plus the
                    // row's clip makes that impossible here.
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 4)
                }
                ForEach(group, id: \.self) { action in
                    PanelHeaderIconButton(
                        systemName: action.systemImage,
                        label: action.label,
                        pointSize: 11,
                        action: { panel.applyFormatting(action) }
                    )
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .clipped()
    }
}
