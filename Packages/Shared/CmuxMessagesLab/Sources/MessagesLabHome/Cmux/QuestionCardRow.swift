import AppKit
import CmuxAgentQuestion
import CmuxHomeCore

/// The Chief's question (`MessagePart.question`, from a `cmux-question` block) as one
/// compact card on an incoming bubble (`QuestionCardRow.kind`):
///
///     MACHINE
///     Create a cloud machine for api?
///     ( 8 GB ✓ )  ( 4 GB )  ( 16 GB )
///     4 vCPU · 2 of 3 machines on Pro                 ← the chosen option's detail (cost line)
///                                         [ Create ]   ← the asker's submit label, tinted
///
/// The first option of each single-choice item starts chosen (the Chief puts its
/// recommendation first), a click on a chip only chooses, and only the tinted button
/// (or Return while the card has the focus) answers: nothing is created by a stray
/// click. Digits 1-9 choose in the first item. The answer goes to the owner as
/// `HomeOp.answerQuestion` (`ChatIntents.answerQuestion`); once the owner stores it
/// (a click, `cmux chief answer`, or a typed reply that names the option) the card
/// collapses to one receipt row in the tool rows' column, "✓ Machine: 8 GB", like a
/// decided approval card. A typed reply that answers something else closes it as
/// "Answered in chat": no live "Create" stays behind.
///
/// References (cmux-design-references): topics/first-run.md and research/first-run.md
/// (concrete next steps with their state, one primary action), topics/approvals.md
/// (the approval card's capsule buttons, the tinted default placed last) and Codex's
/// question card (codex/web: options as rows with a short description under the
/// chosen one).
enum QuestionCardRow {
    static let kind = "cmux.chief.question"

    static func part(_ question: AgentQuestion) -> CustomPart { ChiefRows.part(kind: kind, question) }

    /// The receipt of a closed question: "Machine: 8 GB" (each item's header or prompt and its
    /// chosen labels, items joined by " · "); a Chief card the owner closed for a typed reply,
    /// "Answered in chat"; another harness's cancelled ask, "Cancelled".
    static func receipt(_ question: AgentQuestion) -> String? {
        switch question.state {
        case .pending: return nil
        case .cancelled: return question.source.harness == .chief ? CmuxStrings.questionAnsweredInChat : CmuxStrings.questionCancelled
        case .answered(let answer): return question.summaryLines(answer).joined(separator: " · ")
        }
    }

    // Metrics (points), the approval card's bubble padding and capsule height.
    static let padX: CGFloat = Fixture.bubblePadX
    static let padTop: CGFloat = 8
    static let padBottom: CGFloat = 10
    static let headerHeight: CGFloat = 15
    static let promptGap: CGFloat = 6
    static let chipHeight: CGFloat = 26
    static let chipGap: CGFloat = 6
    static let chipPadX: CGFloat = 12
    static let detailHeight: CGFloat = 16
    static let itemGap: CGFloat = 10
    static let submitGap: CGFloat = 10
    static let submitHeight: CGFloat = 28
    static let receiptHeight: CGFloat = 18
    static let maxWidth: CGFloat = 380

    static let headerFont = HomeFonts.system(ofSize: 11, weight: .semibold)
    static let chipFont = HomeFonts.system(ofSize: 13, weight: .medium)
    static let detailFont = HomeFonts.system(ofSize: 12)
    /// The closed card's receipt row: the approval receipt's font.
    static var receiptFont: NSFont { ChiefApprovalRowProvider.receiptFont }

    static func promptText(_ prompt: String, color: NSColor? = nil) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [.font: Fixture.bodyFont, .paragraphStyle: style]
        if let color { attrs[.foregroundColor] = color }
        return NSAttributedString(string: prompt, attributes: attrs)
    }

    static func promptHeight(_ prompt: String, width: CGFloat) -> CGFloat {
        ceil(promptText(prompt).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    static func chipWidth(_ label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: chipFont]).width) + 2 * chipPadX + 14
    }

    /// Chip frames of one item, wrapped to `width`, relative to the chip block's origin.
    static func chipFrames(_ item: AgentQuestion.Item, width: CGFloat) -> [CGRect] {
        var out: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0
        for option in item.options {
            let w = min(width, chipWidth(option.label))
            if x > 0, x + w > width {
                x = 0
                y += chipHeight + chipGap
            }
            out.append(CGRect(x: x, y: y, width: w, height: chipHeight))
            x += w + chipGap
        }
        return out
    }

    /// One item's block: (header?, prompt, chips, detail line?) heights from its top.
    struct ItemLayout {
        var header: CGRect?
        var prompt: CGRect
        var chips: [CGRect]
        var detail: CGRect?
        var height: CGFloat
    }

    static func itemLayout(_ item: AgentQuestion.Item, width: CGFloat, pending: Bool) -> ItemLayout {
        var y: CGFloat = 0
        var header: CGRect?
        if item.header != nil {
            header = CGRect(x: 0, y: y, width: width, height: headerHeight)
            y += headerHeight + 2
        }
        let promptH = promptHeight(item.prompt, width: width)
        let prompt = CGRect(x: 0, y: y, width: width, height: promptH)
        y += promptH
        guard pending else { return ItemLayout(header: header, prompt: prompt, chips: [], detail: nil, height: y) }
        y += promptGap
        let chips = chipFrames(item, width: width).map { $0.offsetBy(dx: 0, dy: y) }
        y = (chips.map(\.maxY).max() ?? y)
        var detail: CGRect?
        // A detail line is reserved when any option has one, so choosing never changes the height.
        if item.options.contains(where: { $0.detail != nil }) {
            detail = CGRect(x: 0, y: y + 4, width: width, height: detailHeight)
            y += 4 + detailHeight
        }
        return ItemLayout(header: header, prompt: prompt, chips: chips, detail: detail, height: y)
    }

    /// A steady card width: the column's, at most `maxWidth` points (chips wrap inside it).
    static func width(_ question: AgentQuestion, maxWidth: CGFloat) -> CGFloat {
        min(maxWidth, Self.maxWidth)
    }

    static func size(_ question: AgentQuestion, maxWidth: CGFloat) -> CGSize {
        // Closed: one receipt row across the column (the decided approval's).
        guard question.isPending else { return CGSize(width: maxWidth, height: receiptHeight) }
        let w = width(question, maxWidth: maxWidth)
        let inner = w - 2 * padX
        var h = padTop
        for (i, item) in question.items.enumerated() {
            if i > 0 { h += itemGap }
            h += itemLayout(item, width: inner, pending: question.isPending).height
        }
        h += submitGap + submitHeight
        return CGSize(width: w, height: h + padBottom)
    }
}

final class QuestionCardRowProvider: TranscriptCustomRowProvider {
    static let shared = QuestionCardRowProvider()

    let kind = QuestionCardRow.kind
    var measuresOffMain: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout {
        part.decode(AgentQuestion.self)?.isPending == false ? .fullWidth : .bubbleIncoming
    }

    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize {
        guard let q = part.decode(AgentQuestion.self) else { return CGSize(width: 220, height: 40) }
        return QuestionCardRow.size(q, maxWidth: maxWidth)
    }

    func estimate(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { measure(part, maxWidth: maxWidth) }

    func makeView() -> CustomRowPlatformView { QuestionCardView() }

    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {
        guard let v = view as? QuestionCardView, let q = part.decode(AgentQuestion.self) else { return }
        v.show(q, context: context)
    }

    func prepareForReuse(_ view: CustomRowPlatformView) { (view as? QuestionCardView)?.reset() }

    func handleKey(_ key: CustomRowKey, view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) -> Bool {
        (view as? QuestionCardView)?.handle(key) ?? false
    }

    func plainText(_ part: CustomPart) -> String? {
        guard let q = part.decode(AgentQuestion.self) else { return nil }
        return [q.transcriptText, QuestionCardRow.receipt(q)].compactMap { $0 }.joined(separator: "\n")
    }
}

/// The card's live view: drawn headers, prompts and detail lines; chips and the submit button.
final class QuestionCardView: NSView {
    private var question: AgentQuestion?
    private var context: CustomRowContext?
    /// Chosen option ids per item id (local until submitted).
    private var chosen: [String: [String]] = [:]
    private var chips: [[QuestionChip]] = []
    private var submit: ChiefOptionButton?
    /// The question answered from this view, waiting for the owner's echo.
    private var sentID: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription(CmuxStrings.questionRole)
        setAccessibilityIdentifier("ChiefQuestionCard")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func reset() {
        question = nil
        context = nil
        chosen = [:]
        sentID = nil
        chips.flatMap { $0 }.forEach { $0.removeFromSuperview() }
        chips = []
        submit?.removeFromSuperview()
        submit = nil
        toolTip = nil
    }

    func show(_ q: AgentQuestion, context: CustomRowContext) {
        let fresh = question?.id != q.id || question?.isPending != q.isPending || question?.items != q.items
        if question?.id != q.id {
            sentID = nil
            // The recommendation (first option) starts chosen in single-choice items.
            chosen = Dictionary(q.items.map { item in
                (item.id, item.multiSelect ? [] : Array(item.options.prefix(1).map(\.id)))
            }, uniquingKeysWith: { first, _ in first })
        }
        question = q
        self.context = context
        setAccessibilityLabel(q.isPending ? q.items.map(\.prompt).joined(separator: " ") : QuestionCardRow.receipt(q))
        setAccessibilityValue(q.isPending ? nil : QuestionCardRow.receipt(q))
        setAccessibilityRole(q.isPending ? .group : .staticText)
        // The closed card's question is still a hover away.
        toolTip = q.isPending ? nil : q.items.map(\.prompt).joined(separator: "\n")
        if fresh { rebuild(q) }
        refreshControls()
        needsLayout = true
        needsDisplay = true
    }

    private func rebuild(_ q: AgentQuestion) {
        chips.flatMap { $0 }.forEach { $0.removeFromSuperview() }
        submit?.removeFromSuperview()
        submit = nil
        chips = []
        guard q.isPending else { return }
        chips = q.items.map { item in
            item.options.map { option in
                let chip = QuestionChip(label: option.label)
                chip.target = self
                chip.action = #selector(chipClicked(_:))
                chip.toolTip = option.detail
                chip.setAccessibilityHelp(option.detail)
                addSubview(chip)
                return chip
            }
        }
        let title = q.submitLabel ?? CmuxStrings.questionSubmit
        let button = ChiefOptionButton(option: title, style: .prominent)
        button.target = self
        button.action = #selector(submitClicked)
        button.setAccessibilityIdentifier("ChiefQuestionSubmit")
        addSubview(button)
        submit = button
    }

    private func refreshControls() {
        guard let q = question else { return }
        let sending = sentID != nil
        for (i, item) in q.items.enumerated() where i < chips.count {
            for (j, option) in item.options.enumerated() where j < chips[i].count {
                chips[i][j].isChosen = chosen[item.id]?.contains(option.id) == true
                chips[i][j].isEnabled = !sending
            }
        }
        submit?.isEnabled = !sending && canSubmit
    }

    private var answer: AgentQuestionAnswer {
        var selections: [String: AgentQuestionAnswer.Selection] = [:]
        for item in question?.items ?? [] {
            selections[item.id] = AgentQuestionAnswer.Selection(optionIDs: chosen[item.id] ?? [])
        }
        return AgentQuestionAnswer(selections: selections)
    }

    private var canSubmit: Bool {
        guard let q = question, q.isPending else { return false }
        return answer.problems(for: q).isEmpty
    }

    override func layout() {
        super.layout()
        guard let q = question, q.isPending else { return }
        let p = QuestionCardRow.self
        let inner = bounds.width - 2 * p.padX
        var y = p.padTop
        for (i, item) in q.items.enumerated() {
            if i > 0 { y += p.itemGap }
            let l = p.itemLayout(item, width: inner, pending: true)
            for (j, frame) in l.chips.enumerated() where i < chips.count && j < chips[i].count {
                chips[i][j].frame = frame.offsetBy(dx: p.padX, dy: y)
            }
            y += l.height
        }
        if let submit {
            let w = max(96, ceil(submit.intrinsicContentSize.width) + 28)
            submit.frame = NSRect(x: bounds.width - p.padX - w, y: y + p.submitGap, width: w, height: p.submitHeight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let q = question else { return }
        guard q.isPending else { drawReceipt(q); return }
        let p = QuestionCardRow.self
        let inner = bounds.width - 2 * p.padX
        var y = p.padTop
        for (i, item) in q.items.enumerated() {
            if i > 0 { y += p.itemGap }
            let l = p.itemLayout(item, width: inner, pending: q.isPending)
            if let header = item.header, let r = l.header {
                NSAttributedString(string: header.uppercased(with: .current), attributes: [
                    .font: p.headerFont, .foregroundColor: Fixture.secondaryText, .kern: 0.4,
                ]).draw(in: r.offsetBy(dx: p.padX, dy: y))
            }
            p.promptText(item.prompt, color: Fixture.incomingText)
                .draw(with: l.prompt.offsetBy(dx: p.padX, dy: y), options: [.usesLineFragmentOrigin, .usesFontLeading])
            // The cost line: the chosen option's detail (the first chosen in a multi-choice item).
            if let r = l.detail, let id = chosen[item.id]?.first, let detail = item.options.first(where: { $0.id == id })?.detail {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingTail
                NSAttributedString(string: detail, attributes: [
                    .font: p.detailFont, .foregroundColor: Fixture.secondaryText, .paragraphStyle: style,
                ]).draw(in: r.offsetBy(dx: p.padX, dy: y))
            }
            y += l.height
        }
    }

    /// "✓ Machine: 4 GB" (green check) or "○ Answered in chat", the tool rows' column and size.
    private func drawReceipt(_ q: AgentQuestion) {
        guard let receipt = QuestionCardRow.receipt(q) else { return }
        let mid = QuestionCardRow.receiptHeight / 2
        let answered: Bool = { if case .answered = q.state { return true }; return false }()
        let tint: NSColor = answered ? .systemGreen : Fixture.secondaryText
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium).applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        if let img = NSImage(systemSymbolName: answered ? "checkmark.circle.fill" : "bubble.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let s = img.size
            img.draw(in: NSRect(x: (ChiefToolRowView.glyphX + (14 - s.width) / 2).rounded(), y: (mid - s.height / 2).rounded(),
                                width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let label = NSAttributedString(string: receipt, attributes: [
            .font: QuestionCardRow.receiptFont, .foregroundColor: Fixture.secondaryText, .paragraphStyle: style,
        ])
        let limit = max(0, min(bounds.width, ChiefToolRowView.maxLineWidth) - ChiefToolRowView.textX)
        let h = label.size().height
        label.draw(with: NSRect(x: ChiefToolRowView.textX, y: (mid - h / 2).rounded(), width: limit, height: h),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: Input

    @objc private func chipClicked(_ sender: QuestionChip) {
        guard let q = question else { return }
        for (i, row) in chips.enumerated() {
            guard let j = row.firstIndex(where: { $0 === sender }), i < q.items.count else { continue }
            choose(item: q.items[i], option: j)
        }
    }

    private func choose(item: AgentQuestion.Item, option index: Int) {
        guard sentID == nil, item.options.indices.contains(index) else { return }
        let id = item.options[index].id
        if item.multiSelect {
            var ids = chosen[item.id] ?? []
            if let at = ids.firstIndex(of: id) { ids.remove(at: at) } else { ids.append(id) }
            chosen[item.id] = ids
        } else {
            chosen[item.id] = [id]
        }
        refreshControls()
        needsDisplay = true
    }

    @objc private func submitClicked() { send() }

    /// A key while the card has the focus: digits choose in the first item, Return answers.
    func handle(_ key: CustomRowKey) -> Bool {
        guard let q = question, q.isPending else { return false }
        switch key {
        case .digit(let n):
            guard let item = q.items.first, item.options.indices.contains(n - 1) else { return false }
            choose(item: item, option: n - 1)
            return true
        case .enter:
            send()
            return true
        case .escape:
            context?.actions?.resignFocus()
            return true
        default:
            return false
        }
    }

    private func send() {
        guard let q = question, canSubmit, sentID == nil, let ref = context?.ref, let intents = hostIntents else { return }
        sentID = q.id
        refreshControls()
        let id = q.id
        intents.answerQuestion(ref, answer: answer) { [weak self] ok in
            // Refused (offline, answered elsewhere): the controls come back for another try.
            guard let self, !ok, self.sentID == id else { return }
            self.sentID = nil
            self.refreshControls()
        }
        let actions = context?.actions
        DispatchQueue.main.async { actions?.resignFocus() }
    }

    /// The pane's intents (the HomeStore adapter): this view lives in its HostView's overlay.
    private var hostIntents: ChatIntents? {
        var v: NSView? = self
        while let view = v {
            if let host = view as? HostView { return host.controller?.intents }
            v = view.superview
        }
        return nil
    }
}

/// One option chip: quiet capsule; chosen, an accent ring and check, so the tinted
/// submit button stays the only filled control.
final class QuestionChip: NSButton {
    var isChosen = false { didSet { if isChosen != oldValue { restyle() } } }
    private let label: String

    init(label: String) {
        self.label = label
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = QuestionCardRow.chipHeight / 2
        layer?.cornerCurve = .continuous
        setButtonType(.momentaryChange)
        focusRingType = .none
        setAccessibilityLabel(label)
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool { didSet { restyle() } }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        restyle()
    }

    func restyle() {
        let light = Fixture.lightAppearance
        let quiet = light ? NSColor(white: 0, alpha: 0.07) : NSColor(white: 1, alpha: 0.12)
        let accent = NSColor.controlAccentColor
        let fill = isChosen ? accent.withAlphaComponent(light ? 0.14 : 0.24) : quiet
        layer?.backgroundColor = fill.withAlphaComponent(fill.alphaComponent * (isHighlighted ? 0.7 : 1)).cgColor
        layer?.borderWidth = isChosen ? 1 : 0
        layer?.borderColor = accent.withAlphaComponent(0.8).cgColor
        alphaValue = isEnabled ? 1 : 0.5
        setAccessibilityValue(isChosen ? NSNumber(value: 1) : NSNumber(value: 0))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        attributedTitle = NSAttributedString(string: (isChosen ? "✓ " : "") + label, attributes: [
            .font: QuestionCardRow.chipFont, .foregroundColor: Fixture.incomingText, .paragraphStyle: style,
        ])
    }
}
