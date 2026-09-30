import AppKit
import CmuxAcpmux

/// Converts transcript rows into attributed strings for TextKit 1 layout.
///
/// Rendering is deterministic for a given row version, theme, and expansion state, so the
/// layout cache can key on those and skip re-rendering unchanged rows. It holds only
/// immutable values, so layout workers call it off the main thread.
struct AcpmuxChatTextRenderer {
    let theme: AcpmuxChatTheme
    private let parser = MarkdownBlockParser()

    init(theme: AcpmuxChatTheme) {
        self.theme = theme
    }

    // MARK: - Messages

    func userMessage(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: theme.bodyFont,
            .foregroundColor: theme.userText,
            .paragraphStyle: paragraph(spacingAfter: 0),
        ])
    }

    func markdown(_ text: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let blocks = parser.parse(text)
        for (index, block) in blocks.enumerated() {
            let isLast = index == blocks.count - 1
            let spacing: CGFloat = isLast ? 0 : 7
            switch block {
            case .paragraph(let source):
                output.append(inline(source, font: theme.bodyFont, color: theme.foreground, paragraph: paragraph(spacingAfter: spacing)))
            case .heading(let level, let source):
                let size: CGFloat = level <= 1 ? 17 : (level == 2 ? 15.5 : 14)
                output.append(inline(
                    source,
                    font: .systemFont(ofSize: size, weight: .semibold),
                    color: theme.foreground,
                    paragraph: paragraph(spacingAfter: spacing, spacingBefore: index == 0 ? 0 : 3)
                ))
            case .listItem(let marker, let depth, let source):
                let style = paragraph(spacingAfter: isLast ? 0 : 3)
                let indent = CGFloat(depth) * 16
                let markerWidth: CGFloat = marker == "•" ? 14 : 22
                style.firstLineHeadIndent = indent
                style.headIndent = indent + markerWidth
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerWidth)]
                let line = NSMutableAttributedString(string: "\(marker)\t", attributes: [
                    .font: theme.bodyFont,
                    .foregroundColor: theme.secondaryText,
                    .paragraphStyle: style,
                ])
                line.append(inline(source, font: theme.bodyFont, color: theme.foreground, paragraph: style))
                output.append(line)
            case .quote(let source):
                let style = paragraph(spacingAfter: spacing)
                style.firstLineHeadIndent = 10
                style.headIndent = 10
                output.append(inline(source, font: theme.bodyFont, color: theme.secondaryText, paragraph: style))
            case .code(_, let source):
                output.append(codeBlock(source, spacingAfter: spacing))
            case .rule:
                output.append(NSAttributedString(string: "\u{2014}\u{2014}\u{2014}", attributes: [
                    .font: theme.smallFont,
                    .foregroundColor: theme.tertiaryText,
                    .paragraphStyle: paragraph(spacingAfter: spacing),
                ]))
            }
            if !isLast { output.append(NSAttributedString(string: "\n")) }
        }
        if case .code? = blocks.last {
            // TextKit drops paragraph spacing after the final line of the text. A 1 pt
            // spacer line after a closing code block keeps that spacing (the box's bottom inset).
            let spacer = NSMutableParagraphStyle()
            spacer.minimumLineHeight = 1
            spacer.maximumLineHeight = 1
            // A zero-width space, not a trailing newline: a trailing newline adds an extra
            // full-height line fragment at the end of the text.
            output.append(NSAttributedString(string: "\n\u{200B}", attributes: [
                .font: NSFont.systemFont(ofSize: 1),
                .paragraphStyle: spacer,
            ]))
        }
        return output
    }

    private func codeBlock(_ source: String, spacingAfter: CGFloat) -> NSAttributedString {
        // Each line is its own paragraph with a uniform inset; the box behind the block is
        // drawn by `AcpmuxTranscriptTextView` from the `.acpmuxCodeBlock` attribute, so
        // measurement and drawing agree and every line gets the same indent.
        let lines = (source.isEmpty ? " " : source).components(separatedBy: "\n")
        let output = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = Self.codeInset
            style.headIndent = Self.codeInset
            style.tailIndent = -Self.codeInset
            style.lineBreakMode = .byCharWrapping
            // Outer margin plus the box inset above the first line and below the last.
            style.paragraphSpacingBefore = index == 0 ? Self.codeInset + 4 : 0
            style.paragraphSpacing = index == lines.count - 1 ? Self.codeInset + spacingAfter + 2 : 0
            let text = index == lines.count - 1 ? line : line + "\n"
            output.append(NSAttributedString(string: text.isEmpty ? " " : text, attributes: [
                .font: theme.codeFont,
                .foregroundColor: theme.foreground,
                .paragraphStyle: style,
                .acpmuxCodeBlock: theme.codeBackground,
            ]))
        }
        return output
    }

    /// Padding inside a code block box.
    static let codeInset: CGFloat = 8

    private func inline(_ source: String, font: NSFont, color: NSColor, paragraph: NSParagraphStyle) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        guard let parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        ) else {
            return NSAttributedString(string: source, attributes: base)
        }
        let output = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes = base
            let intent = run.inlinePresentationIntent ?? []
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if intent.contains(.code) {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                attributes[.backgroundColor] = theme.codeBackground
            } else if !traits.isEmpty {
                let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                attributes[.font] = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = theme.accent
            }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return output
    }

    // MARK: - Activity, plan, permission, summary

    func activity(_ group: TranscriptActivityGroup, expanded: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let chevron = expanded ? "\u{25BE}" : "\u{25B8}"
        var header = group.isLive
            ? String(localized: "acpmuxChat.activity.working", defaultValue: "Working")
            : String(localized: "acpmuxChat.activity.worked", defaultValue: "Worked")
        if group.toolCount > 0 {
            header += " \u{00B7} " + Self.toolCallCount(group.toolCount)
        }
        output.append(NSAttributedString(string: "\(chevron)  \(header)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: theme.secondaryText,
            .paragraphStyle: paragraph(spacingAfter: 0),
        ]))
        let items: [TranscriptActivityItem]
        if expanded {
            items = group.items
        } else if group.isLive, let latest = group.latest {
            items = [latest]
        } else {
            items = []
        }
        for item in items {
            output.append(NSAttributedString(string: "\n"))
            output.append(activityLine(item, expanded: expanded))
        }
        return output
    }

    private func activityLine(_ item: TranscriptActivityItem, expanded: Bool) -> NSAttributedString {
        let style = paragraph(spacingAfter: 0, spacingBefore: 4)
        style.firstLineHeadIndent = 16
        style.headIndent = 16
        switch item {
        case .thought(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = expanded ? trimmed : String(trimmed.split(separator: "\n").last ?? "")
            return NSAttributedString(string: shown.replacingOccurrences(of: "**", with: ""), attributes: [
                .font: NSFontManager.shared.convert(theme.smallFont, toHaveTrait: .italicFontMask),
                .foregroundColor: theme.tertiaryText,
                .paragraphStyle: style,
            ])
        case .tool(let call):
            let line = NSMutableAttributedString()
            let (glyph, color) = statusGlyph(call.status)
            line.append(NSAttributedString(string: "\(glyph) ", attributes: [
                .font: theme.smallFont, .foregroundColor: color, .paragraphStyle: style,
            ]))
            line.append(NSAttributedString(string: call.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: theme.secondaryText,
                .paragraphStyle: style,
            ]))
            if expanded, let input = call.inputSummary, input != call.title {
                line.append(NSAttributedString(string: "\n" + String(input.prefix(400)), attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: theme.tertiaryText,
                    .paragraphStyle: style,
                ]))
            }
            if expanded, let output = call.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                let preview = output.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")
                line.append(NSAttributedString(string: "\n" + preview, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: theme.tertiaryText,
                    .paragraphStyle: style,
                ]))
            }
            return line
        }
    }

    private func statusGlyph(_ status: String) -> (String, NSColor) {
        switch status {
        case "completed": return ("\u{2713}", theme.success)
        case "failed": return ("\u{2715}", theme.danger)
        case "cancelled": return ("\u{2013}", theme.tertiaryText)
        default: return ("\u{25CB}", theme.accent)
        }
    }

    func plan(_ entries: [TranscriptPlanEntry]) -> NSAttributedString {
        let output = NSMutableAttributedString(string: String(localized: "acpmuxChat.plan.title", defaultValue: "Plan"), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: theme.secondaryText,
            .paragraphStyle: paragraph(spacingAfter: 2),
        ])
        for entry in entries {
            let glyph: String
            switch entry.status {
            case "completed": glyph = "\u{2611}"
            case "in_progress": glyph = "\u{25D0}"
            default: glyph = "\u{2610}"
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: theme.bodyFont,
                .foregroundColor: entry.status == "completed" ? theme.tertiaryText : theme.foreground,
                .paragraphStyle: paragraph(spacingAfter: 2),
            ]
            if entry.status == "completed" { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            output.append(NSAttributedString(string: "\n\(glyph) \(entry.content)", attributes: attributes))
        }
        return output
    }

    func permission(_ card: TranscriptPermissionCard) -> NSAttributedString {
        let title = card.request.toolCall?.title ?? String(localized: "acpmuxChat.permission.fallbackTitle", defaultValue: "Tool call")
        let status: String
        let color: NSColor
        switch card.resolution {
        case nil:
            status = String(localized: "acpmuxChat.permission.waiting", defaultValue: "Waiting for approval")
            color = theme.accent
        case .selected(_, let allowed):
            status = allowed
                ? String(localized: "acpmuxChat.permission.allowed", defaultValue: "Allowed")
                : String(localized: "acpmuxChat.permission.denied", defaultValue: "Denied")
            color = allowed ? theme.success : theme.danger
        case .cancelled:
            status = String(localized: "acpmuxChat.permission.cancelled", defaultValue: "Cancelled")
            color = theme.tertiaryText
        }
        let output = NSMutableAttributedString(attributedString: Self.symbol("lock.shield", color: theme.secondaryText, font: theme.smallFont))
        output.append(NSAttributedString(string: "  \(title)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: theme.secondaryText,
            .paragraphStyle: paragraph(spacingAfter: 0),
        ]))
        output.append(NSAttributedString(string: "  \u{00B7}  \(status)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: color,
        ]))
        return output
    }

    func turnSummary(_ summary: TranscriptTurnSummary) -> NSAttributedString {
        var parts: [String] = []
        switch summary.status {
        case "cancelled":
            parts.append(String(localized: "acpmuxChat.turn.cancelled", defaultValue: "Cancelled"))
        case "failed":
            parts.append(String(localized: "acpmuxChat.turn.failed", defaultValue: "Failed"))
        default:
            if let duration = summary.durationMs {
                let format = String(localized: "acpmuxChat.turn.workedFor", defaultValue: "Worked for %@")
                parts.append(String.localizedStringWithFormat(format, Self.duration(duration)))
            } else {
                parts.append(String(localized: "acpmuxChat.turn.done", defaultValue: "Done"))
            }
        }
        if summary.toolCount > 0 { parts.append(Self.toolCallCount(summary.toolCount)) }
        if let error = summary.error, !error.isEmpty { parts.append(error) }
        let style = paragraph(spacingAfter: 0)
        style.alignment = .center
        let failed = summary.status == "failed"
        let output = NSMutableAttributedString()
        if failed { output.append(Self.symbol("exclamationmark.triangle.fill", color: theme.danger, font: theme.smallFont)) }
        output.append(NSAttributedString(string: (failed ? " " : "") + parts.joined(separator: " \u{00B7} "), attributes: [
            .font: failed ? NSFont.systemFont(ofSize: 11.5, weight: .medium) : theme.smallFont,
            .foregroundColor: failed ? theme.danger : theme.tertiaryText,
        ]))
        output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: output.length))
        return output
    }

    func notice(_ text: String) -> NSAttributedString {
        let style = paragraph(spacingAfter: 0)
        style.alignment = .center
        let output = NSMutableAttributedString(attributedString: Self.symbol("exclamationmark.triangle.fill", color: theme.danger, font: theme.smallFont))
        output.append(NSAttributedString(string: " " + text, attributes: [.font: theme.smallFont, .foregroundColor: theme.danger]))
        output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: output.length))
        return output
    }

    /// An SF Symbol as an inline text attachment tinted `color`.
    static func symbol(_ name: String, color: NSColor, font: NSFont) -> NSAttributedString {
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: font.descender + 1, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    // MARK: - Helpers

    private func paragraph(spacingAfter: CGFloat, spacingBefore: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 1.5
        style.paragraphSpacing = spacingAfter
        style.paragraphSpacingBefore = spacingBefore
        return style
    }

    static func toolCallCount(_ count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "acpmuxChat.toolCallCount", defaultValue: "%lld tool calls"),
            Int64(count)
        )
    }

    static func duration(_ milliseconds: Int64) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = milliseconds >= 3_600_000 ? [.hour, .minute] : (milliseconds >= 60_000 ? [.minute, .second] : [.second])
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(max(1, milliseconds / 1000))) ?? "\(milliseconds / 1000)s"
    }
}
