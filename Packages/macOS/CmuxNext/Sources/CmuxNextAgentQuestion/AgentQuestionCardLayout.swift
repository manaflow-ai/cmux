public import AppKit
public import CmuxAgentQuestion

/// Every frame of a question card for one (question, interaction state,
/// width, style), in flipped coordinates (origin top left). The view draws
/// these frames and the transcript row measures `height`, so both agree.
///
/// The height of a pending card depends only on the active item, the width,
/// the style and whether the Other field is shown: the preview pane reserves
/// the tallest preview of the item, so arrowing through options never moves
/// the transcript.
public struct AgentQuestionCardLayout: Equatable {
    public enum Mode: Equatable { case pending, answered, cancelled }

    public struct Row: Equatable {
        public var frame: CGRect
        public var keycap: CGRect
        public var label: CGRect
        public var detail: CGRect?
        public var check: CGRect
        public var isOther: Bool
    }

    public private(set) var mode: Mode
    public private(set) var height: CGFloat = 0
    public private(set) var chip: CGRect?
    public private(set) var meta: CGRect?
    public private(set) var prompt: CGRect = .zero
    public private(set) var rows: [Row] = []
    public private(set) var otherField: CGRect?
    public private(set) var preview: CGRect?
    public private(set) var hint: CGRect?
    public private(set) var skip: CGRect?
    public private(set) var submit: CGRect?
    /// Answered: one frame per summary line, then the respondent line.
    public private(set) var summary: [CGRect] = []
    public private(set) var check: CGRect?

    @MainActor
    public init(state: AgentQuestionCardState, width: CGFloat, style: AgentQuestionCardStyle = .init()) {
        let measure = AgentQuestionTextMeasure()
        let strings = AgentQuestionStrings()
        switch state.question.state {
        case .pending:
            mode = .pending
            layoutPending(state, width: width, style: style, measure: measure, strings: strings)
        case .answered(let answer):
            mode = .answered
            layoutAnswered(state.question, answer: answer, width: width, style: style, measure: measure, strings: strings)
        case .cancelled:
            mode = .cancelled
            let line = measure.lineHeight(style.metaFont)
            summary = [CGRect(x: style.padding, y: style.size(8), width: max(width - 2 * style.padding, 0), height: line)]
            height = line + 2 * style.size(8)
        }
    }

    @MainActor
    private mutating func layoutPending(_ state: AgentQuestionCardState, width: CGFloat, style: AgentQuestionCardStyle,
                                        measure: AgentQuestionTextMeasure, strings: AgentQuestionStrings) {
        let item = state.item
        let p = style.padding
        let inner = max(width - 2 * p, 1)
        var y = p
        let metaText = Self.metaText(state, strings: strings)
        if item.header != nil || !metaText.isEmpty {
            if let header = item.header {
                let w = min(measure.width(header, font: style.chipFont) + 2 * style.chipInset, inner * 0.6)
                chip = CGRect(x: p, y: y, width: w, height: style.chipHeight)
            }
            let w = min(measure.width(metaText, font: style.metaFont), inner * 0.4)
            let h = measure.lineHeight(style.metaFont)
            meta = CGRect(x: width - p - w, y: y + (style.chipHeight - h) / 2, width: w, height: h)
            y += style.chipHeight + style.size(6)
        }
        let promptHeight = measure.height(item.prompt, font: style.promptFont, width: inner)
        prompt = CGRect(x: p, y: y, width: inner, height: promptHeight)
        y += promptHeight + style.gap

        let sideBySide = item.hasPreviews && width >= style.sideBySideMinWidth
        let listWidth = sideBySide ? (inner * 0.46).rounded() : inner
        let rowsTop = y
        let count = state.rowCount(item)
        let textX = style.rowInset + style.keycapSize + style.size(10)
        let textWidth = max(listWidth - textX - style.checkSize - style.size(8) - style.rowInset, 1)
        for row in 0..<count {
            let isOther = state.isOtherRow(row, in: item)
            let option = isOther ? nil : item.options[row]
            let label = option?.label ?? strings.other
            let labelHeight = measure.height(label, font: style.labelFont, width: textWidth)
            let detailHeight = option?.detail.map { measure.height($0, font: style.detailFont, width: textWidth) } ?? 0
            let content = labelHeight + (detailHeight > 0 ? style.size(2) + detailHeight : 0)
            let rowHeight = max(style.rowMinHeight, content + 2 * style.size(7))
            let frame = CGRect(x: p, y: y, width: listWidth, height: rowHeight)
            let top = y + (rowHeight - content) / 2
            let keycap = CGRect(x: p + style.rowInset, y: y + (rowHeight - style.keycapSize) / 2,
                                width: style.keycapSize, height: style.keycapSize)
            let labelFrame = CGRect(x: p + textX, y: top, width: textWidth, height: labelHeight)
            let detail = detailHeight > 0
                ? CGRect(x: p + textX, y: top + labelHeight + style.size(2), width: textWidth, height: detailHeight) : nil
            let check = CGRect(x: p + listWidth - style.rowInset - style.checkSize, y: y + (rowHeight - style.checkSize) / 2,
                               width: style.checkSize, height: style.checkSize)
            rows.append(Row(frame: frame, keycap: keycap, label: labelFrame, detail: detail, check: check, isOther: isOther))
            y += rowHeight + style.rowGap
        }
        if let other = rows.last, other.isOther, state.editingOther || state.otherDrafts[item.id]?.isEmpty == false {
            let fieldHeight = measure.lineHeight(style.labelFont) + style.size(6)
            otherField = CGRect(x: other.label.minX - style.size(3), y: other.frame.midY - fieldHeight / 2,
                                width: other.label.width + style.size(3), height: fieldHeight)
        }
        let listBottom = y - style.rowGap
        if item.hasPreviews {
            let previewWidth = sideBySide ? inner - listWidth - style.gap : inner
            let tallest = item.options.compactMap(\.preview).map {
                measure.height($0.text, font: style.previewFont, width: previewWidth - 2 * style.previewInset)
            }.max() ?? 0
            let previewHeight = max(tallest + 2 * style.previewInset, style.previewMinHeight)
            if sideBySide {
                let pane = CGRect(x: p + listWidth + style.gap, y: rowsTop, width: previewWidth,
                                  height: max(previewHeight, listBottom - rowsTop))
                preview = pane
                y = max(listBottom, pane.maxY)
            } else {
                preview = CGRect(x: p, y: listBottom + style.gap, width: inner, height: previewHeight)
                y = listBottom + style.gap + previewHeight
            }
        } else {
            y = listBottom
        }
        y += style.gap
        let submitWidth = measure.width(strings.submit, font: style.buttonFont) + 2 * style.buttonInset
        let skipWidth = measure.width(strings.skip, font: style.buttonFont) + 2 * style.buttonInset
        submit = CGRect(x: width - p - submitWidth, y: y, width: submitWidth, height: style.buttonHeight)
        skip = CGRect(x: width - p - submitWidth - style.size(6) - skipWidth, y: y, width: skipWidth, height: style.buttonHeight)
        let hintHeight = measure.lineHeight(style.metaFont)
        let hintWidth = max((skip?.minX ?? width) - p - style.gap, 0)
        let hintText = state.item.multiSelect ? strings.multiHint : strings.hint
        // A key hint that does not fit is left out (the keycaps still show the numbers).
        if measure.width(hintText, font: style.metaFont) <= hintWidth {
            hint = CGRect(x: p, y: y + (style.buttonHeight - hintHeight) / 2, width: hintWidth, height: hintHeight)
        }
        height = y + style.buttonHeight + p
    }

    @MainActor
    private mutating func layoutAnswered(_ question: AgentQuestion, answer: AgentQuestionAnswer, width: CGFloat,
                                         style: AgentQuestionCardStyle, measure: AgentQuestionTextMeasure,
                                         strings: AgentQuestionStrings) {
        let p = style.size(10)
        let x = p + style.checkSize + style.size(8)
        let textWidth = max(width - x - p, 1)
        var y = p
        check = CGRect(x: p, y: y + style.size(2), width: style.checkSize, height: style.checkSize)
        for line in question.summaryLines(answer) {
            let h = measure.height(line, font: style.summaryFont, width: textWidth)
            summary.append(CGRect(x: x, y: y, width: textWidth, height: h))
            y += h + style.size(2)
        }
        let h = measure.lineHeight(style.metaFont)
        summary.append(CGRect(x: x, y: y, width: textWidth, height: h))
        height = y + h + p
    }

    /// "Claude Code · 2 of 4", or just one of them.
    static func metaText(_ state: AgentQuestionCardState, strings: AgentQuestionStrings) -> String {
        var parts: [String] = []
        if let agent = state.question.source.agentName { parts.append(agent) }
        if state.question.items.count > 1 { parts.append(strings.pager(state.activeItem + 1, of: state.question.items.count)) }
        return parts.joined(separator: " · ")
    }
}
