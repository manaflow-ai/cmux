#if os(iOS)
import CmuxMobileDesign
import CmuxMobileDiff
import CmuxMobileMarkdown
import UIKit

/// The transcript's common non-markdown rows laid out for UIKit, matching their SwiftUI
/// views at rest: the prompt bubble (`UserBubble`), a finished tool row (`ToolRowView`) and
/// group (`ToolGroupView`), a closed thought (`ThoughtRow`), the diff snippet (`DiffSnippet`),
/// the edited-files card (`EditedFilesCard`) and the answer's action row (`AnswerActionRow`).
/// Their other states (running, open, accessibility sizes) stay SwiftUI.
struct ChatNativeWidgets {
    let width: CGFloat
    let styles: NativeTextStyles
    private let wording = ToolWording()

    init(width: CGFloat, styles: NativeTextStyles) {
        self.width = width
        self.styles = styles
    }

    typealias Layout = ChatNativeLayout
    typealias Drawn = ChatNativeLayout.Drawn

    func make(_ kind: ChatRow.Kind, id: String, expanded: Bool) -> Layout? {
        switch kind {
        case .prompt(let text, let attachments, _, _):
            return attachments.isEmpty ? prompt(text) : nil
        case .thought(_, let isLive):
            return isLive ? nil : header(symbol: "brain", symbolColor: .secondaryLabel, title: "Thought", key: "thought-\(id)")
        case .tool(let call):
            return call.isRunning ? nil : tool(call)
        case .toolGroup(let calls, _):
            return calls.contains(where: \.isRunning) ? nil : group(calls)
        case .edit(let call, let files):
            guard !call.isRunning, let files else { return nil }
            return snippet(call, files: files, expanded: expanded)
        case .editedFiles(let changes):
            return editedFiles(changes)
        case .actions(let turn, let isLast):
            return actions(turn, isLast: isLast)
        default:
            return nil
        }
    }

    // MARK: Pieces

    private func text(_ string: String, _ font: UIFont, _ color: UIColor, lineBreak: NSLineBreakMode = .byTruncatingTail,
                      lineSpacing: CGFloat = 0) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreak
        paragraph.lineSpacing = lineSpacing
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private func size(_ text: NSAttributedString, width: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        Layout.measure(text, width: width)
    }

    /// One line of text, cut to `maxWidth`, its height one line.
    private func line(_ text: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let natural = size(text)
        let font = text.length > 0 ? (text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont) : nil
        return CGSize(width: min(natural.width, max(maxWidth, 0)), height: ceil((font?.lineHeight ?? natural.height) * 3) / 3)
    }

    private func symbolSize(_ name: String, _ font: UIFont) -> CGSize {
        ChatSymbols.image(name, font)?.size ?? CGSize(width: font.pointSize, height: font.pointSize)
    }

    /// `+12 −4` in diff colors, 4 pt apart (`DiffCounts`).
    private func counts(additions: Int, deletions: Int) -> NSAttributedString {
        let font = UIFont.monospacedDigitSystemFont(ofSize: styles.font(.footnote).pointSize, weight: .medium)
        let output = NSMutableAttributedString(string: "+\(additions)", attributes: [.font: font, .foregroundColor: UIColor.cmuxMobileDiffAddText])
        output.addAttribute(.kern, value: 4, range: NSRange(location: output.length - 1, length: 1))
        output.append(NSAttributedString(string: "−\(deletions)", attributes: [.font: font, .foregroundColor: UIColor.cmuxMobileDiffDelText]))
        return output
    }

    private func fixed(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: weight)
    }

    // MARK: Prompt

    /// `UserBubble`: body text with 4 pt line spacing in the bubble color, 16/11 pt padding,
    /// radius 20, at most 80% of the column, on the trailing edge.
    private func prompt(_ prompt: String) -> Layout {
        let attributed = text(prompt, styles.font(.body), .label, lineBreak: .byWordWrapping, lineSpacing: 4)
        let maxText = width * 0.8 - 32
        let measured = size(attributed, width: maxText)
        // SwiftUI's height: n lines 4 pt apart (TextKit also counts the spacing under the last line).
        let lines = Layout.lineCount(attributed, width: maxText)
        let lineHeight = (styles.font(.body).lineHeight * 3).rounded(.up) / 3
        let textHeight = CGFloat(lines) * lineHeight + CGFloat(lines - 1) * 4
        let bubble = CGSize(width: min(measured.width, maxText) + 32, height: textHeight + 22)
        let x = width - bubble.width
        var drawn = Drawn()
        drawn.boxes.append(.init(frame: CGRect(x: x, y: 0, width: bubble.width, height: bubble.height), fill: .cmuxMobileBubble, radius: 20))
        drawn.texts.append(.init(text: attributed, frame: CGRect(x: x + 16, y: 11, width: bubble.width - 32, height: max(textHeight, measured.height))))
        return Layout(content: .drawn(drawn), height: bubble.height)
    }

    // MARK: Tool rows

    /// A disclosure header at rest: an 18 pt symbol column, the title, a trailing chevron, on
    /// a 32 pt row whose 44 pt target reaches into the gaps (`ToolRowView`, `ThoughtRow`).
    private func header(symbol: String, symbolColor: UIColor, title: String, key: String?) -> Layout {
        var drawn = Drawn()
        let font = styles.font(.subheadline)
        let titleText = text(title, font, .secondaryLabel, lineBreak: .byWordWrapping)
        let chevron = chevronSymbol()
        let avail = width - 18 - 8 - 4 - chevron.frame.width
        let titleSize = size(titleText, width: avail)
        let height = max(44, titleSize.height) - 12
        placeSymbol(&drawn, symbol, fixed(14), symbolColor, x: 0, width: 18, midY: height / 2)
        drawn.texts.append(.init(text: titleText, frame: CGRect(x: 26, y: (height - titleSize.height) / 2, width: titleSize.width, height: titleSize.height)))
        var mark = chevron
        mark.frame.origin = CGPoint(x: width - mark.frame.width, y: (height - mark.frame.height) / 2)
        drawn.symbols.append(mark)
        if let key {
            drawn.hits.append(.init(frame: CGRect(x: 0, y: -6, width: width, height: height + 12), hit: .toggle(key), label: title, isDisclosure: true))
        }
        drawn.accessibilityLabel = title
        return Layout(content: .drawn(drawn), height: height)
    }

    private func chevronSymbol() -> Layout.Symbol {
        let font = fixed(11, weight: .semibold)
        let size = symbolSize("chevron.right", font)
        return Layout.Symbol(name: "chevron.right", font: font, color: .tertiaryLabel, frame: CGRect(origin: .zero, size: size))
    }

    private func placeSymbol(_ drawn: inout Drawn, _ name: String, _ font: UIFont, _ color: UIColor, x: CGFloat, width: CGFloat, midY: CGFloat) {
        let size = symbolSize(name, font)
        drawn.symbols.append(.init(name: name, font: font, color: color,
                                   frame: CGRect(x: x + (width - size.width) / 2, y: midY - size.height / 2, width: size.width, height: size.height)))
    }

    /// `ToolRowView` closed and finished: symbol, verb, the mono object cut at its tail
    /// (commands) or middle (paths), a failed exit code, the chevron.
    private func tool(_ call: ACPToolCall) -> Layout {
        var drawn = Drawn()
        let font = styles.font(.subheadline)
        let (verb, object) = wording.verb(call)
        let verbText = text(verb, font, .secondaryLabel, lineBreak: .byWordWrapping)
        let chevron = chevronSymbol()
        var exit: NSAttributedString?
        if let code = call.exitCode, code != 0 { exit = text("Exit \(code)", styles.font(.footnote), .cmuxMobileDanger) }
        let exitWidth = exit.map { size($0).width + 8 } ?? 0
        let avail = width - 26 - 4 - chevron.frame.width - exitWidth
        // The verb keeps its width first (layout priority); the object takes what is left.
        let verbSize = size(verbText, width: avail)
        let height = max(44, verbSize.height) - 12
        let midY = height / 2
        placeSymbol(&drawn, wording.symbol(call), fixed(14), call.isFailed ? .cmuxMobileDanger : .secondaryLabel, x: 0, width: 18, midY: midY)
        drawn.texts.append(.init(text: verbText, frame: CGRect(x: 26, y: midY - verbSize.height / 2, width: verbSize.width, height: verbSize.height)))
        var x = 26 + verbSize.width + 8
        if let object {
            let monoFont = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            let objectText = text(object, monoFont, .secondaryLabel, lineBreak: call.kind == .execute ? .byTruncatingTail : .byTruncatingMiddle)
            let objectSize = line(objectText, maxWidth: width - x - 4 - chevron.frame.width - exitWidth)
            if objectSize.width > 0 {
                drawn.texts.append(.init(text: objectText, frame: CGRect(x: x, y: midY - objectSize.height / 2, width: objectSize.width, height: objectSize.height)))
                x += objectSize.width + 8
            }
        }
        if let exit {
            let exitSize = size(exit)
            drawn.texts.append(.init(text: exit, frame: CGRect(x: x, y: midY - exitSize.height / 2, width: exitSize.width, height: exitSize.height)))
        }
        var mark = chevron
        mark.frame.origin = CGPoint(x: width - mark.frame.width, y: midY - mark.frame.height / 2)
        drawn.symbols.append(mark)
        let label = ([verb, object].compactMap { $0 } + (exit.map { [$0.string] } ?? [])).joined(separator: " ")
        drawn.hits.append(.init(frame: CGRect(x: 0, y: -6, width: width, height: height + 12), hit: .toggle("tool-\(call.id)"), label: label, isDisclosure: true))
        drawn.accessibilityLabel = label
        return Layout(content: .drawn(drawn), height: height)
    }

    /// `ToolGroupView` closed and finished: the run's summary and its duration.
    private func group(_ calls: [ACPToolCall]) -> Layout {
        var drawn = Drawn()
        let failed = calls.contains(where: \.isFailed)
        let font = styles.font(.subheadline)
        let summary = text(wording.summary(calls), font, .secondaryLabel, lineBreak: .byWordWrapping)
        let chevron = chevronSymbol()
        var duration: NSAttributedString?
        if let start = calls.compactMap(\.startedAt).min(), let end = calls.compactMap(\.endedAt).max() {
            let digits = UIFont.monospacedDigitSystemFont(ofSize: styles.font(.footnote).pointSize, weight: .regular)
            duration = text(wording.duration(end.timeIntervalSince(start)), digits, .tertiaryLabel)
        }
        let durationWidth = duration.map { size($0).width + 8 } ?? 0
        let avail = width - 26 - 4 - 8 - chevron.frame.width - durationWidth
        let summarySize = size(summary, width: avail)
        let height = max(44, summarySize.height) - 12
        let midY = height / 2
        placeSymbol(&drawn, failed ? "exclamationmark.triangle.fill" : "square.stack.3d.down.right", fixed(14),
                    failed ? .cmuxMobileDanger : .secondaryLabel, x: 0, width: 18, midY: midY)
        drawn.texts.append(.init(text: summary, frame: CGRect(x: 26, y: midY - summarySize.height / 2, width: summarySize.width, height: summarySize.height)))
        var mark = chevron
        mark.frame.origin = CGPoint(x: width - mark.frame.width, y: midY - mark.frame.height / 2)
        if let duration {
            let durationSize = size(duration)
            drawn.texts.append(.init(text: duration, frame: CGRect(x: mark.frame.minX - 8 - durationSize.width, y: midY - durationSize.height / 2,
                                                                    width: durationSize.width, height: durationSize.height)))
        }
        drawn.symbols.append(mark)
        let label = [wording.summary(calls), duration?.string].compactMap { $0 }.joined(separator: ", ")
        drawn.hits.append(.init(frame: CGRect(x: 0, y: -6, width: width, height: height + 12), hit: .toggle("group-\(calls.first?.id ?? "")"),
                                label: label, isDisclosure: true))
        drawn.accessibilityLabel = label
        return Layout(content: .drawn(drawn), height: height)
    }

    // MARK: Diff snippet

    /// `DiffSnippet`: one card per file, a 44 pt header that opens the diff, the first 12
    /// changed lines (400 once shown in full) in a sideways scroll area, "Show N more lines".
    private func snippet(_ call: ACPToolCall, files: [ChatDiffCache.EditPreview], expanded: Bool) -> Layout {
        var drawn = Drawn()
        var y: CGFloat = 0
        let footnote = styles.font(.footnote)
        let codeSize = styles.scaled(13, relativeTo: .footnote)
        let mono = UIFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
        for (index, edit) in files.enumerated() {
            if index > 0 { y += 8 }
            let file = edit.file
            let top = y
            // Header.
            let mid = y + 22
            placeSymbol(&drawn, call.isRunning ? "pencil" : (file.status == .added ? "doc.badge.plus" : "pencil"), fixed(13), .secondaryLabel,
                        x: 16, width: symbolSize("pencil", fixed(13)).width, midY: mid)
            var x = 16 + symbolSize("pencil", fixed(13)).width + 6
            let verb = text(file.status == .added ? "Created" : "Edited", UIFont.systemFont(ofSize: footnote.pointSize, weight: .medium), .secondaryLabel)
            let verbSize = size(verb)
            drawn.texts.append(.init(text: verb, frame: CGRect(x: x, y: mid - verbSize.height / 2, width: verbSize.width, height: verbSize.height)))
            x += verbSize.width + 6
            let arrowFont = fixed(12, weight: .semibold)
            let arrow = symbolSize("arrow.up.right", arrowFont)
            let countText = counts(additions: file.additions, deletions: file.deletions)
            let countSize = size(countText)
            let name = text(file.fileName, UIFont.monospacedSystemFont(ofSize: footnote.pointSize, weight: .medium), .label)
            let nameSize = line(name, maxWidth: width - 16 - arrow.width - 4 - countSize.width - 6 - x)
            drawn.texts.append(.init(text: name, frame: CGRect(x: x, y: mid - nameSize.height / 2, width: nameSize.width, height: nameSize.height)))
            x += nameSize.width + 6
            drawn.texts.append(.init(text: countText, frame: CGRect(x: x, y: mid - countSize.height / 2, width: countSize.width, height: countSize.height)))
            drawn.symbols.append(.init(name: "arrow.up.right", font: arrowFont, color: .secondaryLabel,
                                       frame: CGRect(x: width - 16 - arrow.width, y: mid - arrow.height / 2, width: arrow.width, height: arrow.height)))
            drawn.hits.append(.init(frame: CGRect(x: 0, y: top, width: width, height: 44), hit: .openDiff(fileID: file.id),
                                    label: "\(file.status == .added ? "Created" : "Edited") \(file.fileName), \(file.additions) additions, \(file.deletions) deletions. Open diff"))
            y += 44
            // Lines: a 14 pt marker column, then the line, unwrapped.
            let preview = expanded ? edit.long : edit.short
            let body = NSMutableAttributedString()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
            paragraph.defaultTabInterval = 14
            for (n, diffLine) in preview.lines.enumerated() {
                let color: UIColor = diffLine.kind == .added ? .cmuxMobileDiffAddText : (diffLine.kind == .removed ? .cmuxMobileDiffDelText : .secondaryLabel)
                let marker = diffLine.kind == .added ? "+" : (diffLine.kind == .removed ? "−" : " ")
                body.append(NSAttributedString(string: marker + "\t" + (diffLine.text.isEmpty ? " " : diffLine.text) + (n < preview.lines.count - 1 ? "\n" : ""),
                                               attributes: [.font: mono, .foregroundColor: color, .paragraphStyle: paragraph]))
            }
            let bodySize = size(body)
            let lineHeight = ceil(mono.lineHeight * 3) / 3
            let bodyHeight = max(bodySize.height, CGFloat(preview.lines.count) * lineHeight)
            let bottom: CGFloat = preview.remaining > 0 ? 4 : 16
            drawn.scrollers.append(.init(frame: CGRect(x: 0, y: y, width: width, height: bodyHeight + bottom),
                                         text: .init(text: body, frame: CGRect(x: 16, y: 0, width: bodySize.width, height: bodyHeight)),
                                         contentWidth: bodySize.width + 32))
            y += bodyHeight + bottom
            if preview.remaining > 0 {
                let more = text(preview.remaining == 1 ? "Show 1 more line" : "Show \(preview.remaining) more lines",
                                UIFont.systemFont(ofSize: footnote.pointSize, weight: .semibold), .label)
                let moreSize = size(more)
                drawn.texts.append(.init(text: more, frame: CGRect(x: 16, y: y + 22 - moreSize.height / 2, width: moreSize.width, height: moreSize.height)))
                drawn.hits.append(.init(frame: CGRect(x: 0, y: y, width: width, height: 44), hit: .toggle("diff-\(call.id)"), label: more.string))
                y += 44 + 2
            }
            drawn.boxes.append(.init(frame: CGRect(x: 0, y: top, width: width, height: y - top), fill: .cmuxMobileCodeBackground, radius: 20, bordered: true))
        }
        return Layout(content: .drawn(drawn), height: y)
    }

    // MARK: Edited files

    /// `EditedFilesCard`: "N files changed +a −d … Review ›" over one row per file.
    private func editedFiles(_ changes: DiffChangeSet) -> Layout {
        var drawn = Drawn()
        let subheadline = styles.font(.subheadline)
        let semibold = UIFont.systemFont(ofSize: subheadline.pointSize, weight: .semibold)
        let mid: CGFloat = 24
        placeSymbol(&drawn, "plus.forwardslash.minus", fixed(14), .label, x: 16, width: symbolSize("plus.forwardslash.minus", fixed(14)).width, midY: mid)
        var x = 16 + symbolSize("plus.forwardslash.minus", fixed(14)).width + 8
        let title = text("\(changes.files.count) \(changes.files.count == 1 ? "file" : "files") changed", semibold, .label)
        let titleSize = size(title)
        drawn.texts.append(.init(text: title, frame: CGRect(x: x, y: mid - titleSize.height / 2, width: titleSize.width, height: titleSize.height)))
        x += titleSize.width + 8
        let countText = counts(additions: changes.additions, deletions: changes.deletions)
        let countSize = size(countText)
        drawn.texts.append(.init(text: countText, frame: CGRect(x: x, y: mid - countSize.height / 2, width: countSize.width, height: countSize.height)))
        var chevron = chevronSymbol()
        chevron.frame.origin = CGPoint(x: width - 16 - chevron.frame.width, y: mid - chevron.frame.height / 2)
        drawn.symbols.append(chevron)
        let review = text("Review", semibold, .label)
        let reviewSize = size(review)
        drawn.texts.append(.init(text: review, frame: CGRect(x: chevron.frame.minX - 8 - reviewSize.width, y: mid - reviewSize.height / 2,
                                                              width: reviewSize.width, height: reviewSize.height)))
        drawn.hits.append(.init(frame: CGRect(x: 0, y: 0, width: width, height: 48), hit: .openDiff(fileID: nil),
                                label: "\(title.string), \(changes.additions) additions, \(changes.deletions) deletions. Review"))
        drawn.separators.append(CGRect(x: 16, y: 48, width: width - 16, height: 1 / 3.0))
        var y: CGFloat = 48 + 1 / 3.0
        let mono = UIFont.monospacedSystemFont(ofSize: subheadline.pointSize, weight: .regular)
        let footnote = styles.font(.footnote)
        for (fileIndex, file) in changes.files.enumerated() {
            let rowMid = y + 22
            // The viewed mark is drawn by the cell (it changes without the layout).
            drawn.viewedMarks.append((drawn.symbols.count, fileIndex))
            placeSymbol(&drawn, file.status == .added ? "doc.badge.plus" : "doc.text", fixed(13), .secondaryLabel, x: 16, width: 18, midY: rowMid)
            let rowCounts = counts(additions: file.additions, deletions: file.deletions)
            let rowCountSize = size(rowCounts)
            let nameX: CGFloat = 16 + 18 + 10
            let available = width - 16 - rowCountSize.width - 4 - 10 - nameX
            let name = text(file.fileName, mono, .label, lineBreak: .byTruncatingMiddle)
            let folder = text(file.directory, footnote, .tertiaryLabel, lineBreak: .byTruncatingHead)
            let widths = FolderNameLayout.widths(folderIdeal: file.directory.isEmpty ? 0 : size(folder).width, nameIdeal: size(name).width,
                                                 available: available, minimumFolder: 36, spacing: 10)
            let nameSize = line(name, maxWidth: widths.name)
            drawn.texts.append(.init(text: name, frame: CGRect(x: nameX, y: rowMid - nameSize.height / 2, width: widths.name, height: nameSize.height)))
            if widths.folder > 0 {
                let folderHeight = line(folder, maxWidth: widths.folder).height
                drawn.texts.append(.init(text: folder, frame: CGRect(x: nameX + widths.name + 10, y: rowMid - folderHeight / 2,
                                                                      width: widths.folder, height: folderHeight)))
            }
            drawn.texts.append(.init(text: rowCounts, frame: CGRect(x: width - 16 - rowCountSize.width, y: rowMid - rowCountSize.height / 2,
                                                                     width: rowCountSize.width, height: rowCountSize.height)))
            drawn.hits.append(.init(frame: CGRect(x: 0, y: y, width: width, height: 44), hit: .openDiff(fileID: file.id),
                                    label: "\(file.fileName), \(file.additions) additions, \(file.deletions) deletions", file: fileIndex))
            y += 44
        }
        drawn.boxes.insert(.init(frame: CGRect(x: 0, y: 0, width: width, height: y), fill: .cmuxMobileCard, radius: 20), at: 0)
        return Layout(content: .drawn(drawn), height: y)
    }

    // MARK: Actions

    /// `AnswerActionRow`: copy, share, retry (newest turn), a "More" menu, the duration; 44 pt
    /// targets starting 14 pt left of the column.
    private func actions(_ turn: AgentTurn, isLast: Bool) -> Layout? {
        guard !styles.isAccessibilitySize else { return nil }
        var drawn = Drawn()
        let glyphFont = fixed(styles.scaled(16, relativeTo: .body))
        let target = max(44, glyphFont.pointSize * 2)
        var x: CGFloat = -14
        var names = ["doc.on.doc", "square.and.arrow.up"]
        if isLast { names.append("arrow.clockwise") }
        for (index, name) in names.enumerated() {
            placeSymbol(&drawn, name, glyphFont, .secondaryLabel, x: x, width: target, midY: target / 2)
            let hit: ChatNativeLayout.Hit = index == 0 ? .copyAnswer(symbol: drawn.symbols.count - 1) : (index == 1 ? .shareAnswer : .retry)
            drawn.hits.append(.init(frame: CGRect(x: x, y: 0, width: target, height: target), hit: hit, label: ["Copy", "Share", "Retry"][index]))
            x += target
        }
        placeSymbol(&drawn, "ellipsis", glyphFont, .secondaryLabel, x: x, width: target, midY: target / 2)
        drawn.menuButton = CGRect(x: x, y: 0, width: target, height: target)
        if let duration = turn.duration {
            let digits = UIFont.monospacedDigitSystemFont(ofSize: styles.font(.footnote).pointSize, weight: .regular)
            let label = text(wording.duration(duration), digits, .tertiaryLabel)
            let labelSize = size(label)
            drawn.texts.append(.init(text: label, frame: CGRect(x: width - labelSize.width, y: (target - labelSize.height) / 2,
                                                                 width: labelSize.width, height: labelSize.height)))
        }
        return Layout(content: .drawn(drawn), height: target)
    }
}
#endif
