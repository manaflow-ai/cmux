public import AppKit
public import CmuxAgentQuestion
import CmuxNextDesign

/// The question card: one view for Home transcript rows, agent panes and the
/// UI Gallery. It renders `AgentQuestionCardState` with the frames of
/// `AgentQuestionCardLayout` and turns keys and clicks into reducer inputs.
///
/// Only a person's key or click submits: `onSubmit` fires from `keyDown`,
/// `mouseDown`, the Submit button or VoiceOver press, never from
/// `configure` or `replayForPreview`. Nothing answers on a timer.
public final class AgentQuestionCardView: NSView {
    /// The person submitted these choices. The host encodes and sends them.
    public var onSubmit: ((AgentQuestion, AgentQuestionAnswer) -> Void)?
    /// The person chose Skip. The host declines the ask.
    public var onDecline: ((AgentQuestion) -> Void)?
    /// Escape outside the Other field: give the keyboard back (the composer).
    public var onResign: (() -> Void)?
    /// The height changed (the active item, the Other field). The host
    /// re-measures with `AgentQuestionCardLayout`.
    public var onHeightChange: (() -> Void)?

    public private(set) var cardState: AgentQuestionCardState?
    public private(set) var style = AgentQuestionCardStyle()
    private var layoutCache: AgentQuestionCardLayout?
    private var cardWidth: CGFloat = 0
    private let strings = AgentQuestionStrings()

    private let chip = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let prompt = NSTextField(wrappingLabelWithString: "")
    private var rowViews: [AgentQuestionOptionRowView] = []
    let otherField = AgentQuestionOtherField()
    private let previewBox = NSView()
    private let previewText = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let skipButton = AgentQuestionPillButton()
    private let submitButton = AgentQuestionPillButton()
    private let check = NSImageView()
    private var summaryLabels: [NSTextField] = []

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { cardState?.question.isPending == true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        for label in [chip, meta, prompt, previewText, hint] {
            label.isSelectable = false
            addSubview(label)
        }
        chip.wantsLayer = true
        chip.alignment = .center
        chip.lineBreakMode = .byTruncatingTail
        meta.alignment = .right
        meta.lineBreakMode = .byTruncatingTail
        hint.lineBreakMode = .byTruncatingTail
        previewBox.wantsLayer = true
        previewBox.layer?.cornerCurve = .continuous
        addSubview(previewBox, positioned: .below, relativeTo: previewText)
        previewText.setAccessibilityLabel(strings.preview)
        otherField.placeholderString = strings.otherPlaceholder
        otherField.card = self
        addSubview(otherField)
        skipButton.title = strings.skip
        skipButton.target = self
        skipButton.action = #selector(skipPressed)
        submitButton.title = strings.submit
        submitButton.isPrimary = true
        submitButton.target = self
        submitButton.action = #selector(submitPressed)
        addSubview(skipButton)
        addSubview(submitButton)
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        addSubview(check)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") } // crash-allow: never decoded from a nib

    /// Shows `question` at `width`. A pending question keeps the person's
    /// local choices across updates of the same ask; a new ask starts fresh.
    public func configure(question: AgentQuestion, width: CGFloat, style: AgentQuestionCardStyle = .init()) {
        if var state = cardState, state.question.id == question.id {
            state.update(question)
            cardState = state
        } else {
            cardState = AgentQuestionCardState(question: question)
        }
        self.style = style
        cardWidth = width
        refresh()
    }

    /// The card's height for `question` at `width` before any interaction.
    public static func height(for question: AgentQuestion, width: CGFloat, style: AgentQuestionCardStyle = .init()) -> CGFloat {
        AgentQuestionCardLayout(state: AgentQuestionCardState(question: question), width: width, style: style).height
    }

    /// The current height (after interaction).
    public var currentHeight: CGFloat { layoutCache?.height ?? 0 }

    /// Applies inputs for a gallery or fixture picture (a highlighted row, a
    /// typed Other draft). A submit or decline from these inputs is dropped.
    public func replayForPreview(_ inputs: [AgentQuestionCardState.Input]) {
        guard var state = cardState else { return }
        for input in inputs { _ = state.send(input) }
        cardState = state
        refresh()
    }

    /// Runs one input from a person and acts on the reducer's effect.
    func handle(_ input: AgentQuestionCardState.Input) {
        guard var state = cardState else { return }
        let before = layoutCache?.height
        let effect = state.send(input)
        cardState = state
        refresh()
        switch effect {
        case .none: break
        case .submit(let answer): onSubmit?(state.question, answer)
        case .beginOtherEditing: window?.makeFirstResponder(otherField)
        case .resign:
            window?.makeFirstResponder(nil)
            onResign?()
        }
        if before != layoutCache?.height { onHeightChange?() }
    }

    @objc private func skipPressed() {
        guard let question = cardState?.question, question.isPending else { return }
        onDecline?(question)
    }

    @objc private func submitPressed() { handle(.submit) }

    private func refresh() {
        guard let state = cardState else { return }
        let layout = AgentQuestionCardLayout(state: state, width: cardWidth, style: style)
        layoutCache = layout
        let pending = layout.mode == .pending
        for view in [chip, meta, prompt, previewBox, previewText, hint, skipButton, submitButton] as [NSView] {
            view.isHidden = !pending
        }
        hint.isHidden = layout.hint == nil
        check.isHidden = layout.mode != .answered
        otherField.isHidden = layout.otherField == nil
        if pending { configurePending(state, layout) } else { rowViews.forEach { $0.isHidden = true } }
        configureSummary(state, layout)
        setAccessibilityLabel(state.question.items.map(\.prompt).joined(separator: " "))
        applyColors()
        needsLayout = true
    }

    private func configurePending(_ state: AgentQuestionCardState, _ layout: AgentQuestionCardLayout) {
        let item = state.item
        chip.stringValue = item.header ?? ""
        chip.isHidden = item.header == nil
        chip.font = style.chipFont
        meta.stringValue = AgentQuestionCardLayout.metaText(state, strings: strings)
        meta.font = style.metaFont
        prompt.stringValue = item.prompt
        prompt.font = style.promptFont
        while rowViews.count < layout.rows.count {
            let row = AgentQuestionOptionRowView()
            addSubview(row, positioned: .below, relativeTo: otherField)
            rowViews.append(row)
        }
        for (index, row) in rowViews.enumerated() {
            guard index < layout.rows.count else { row.isHidden = true; continue }
            row.isHidden = false
            let frames = layout.rows[index]
            let option = frames.isOther ? nil : item.options[index]
            let chosen = option.map { state.isChosen($0, in: item) } ?? (state.otherDrafts[item.id]?.isEmpty == false)
            let editing = frames.isOther && layout.otherField != nil
            let content = AgentQuestionOptionRowView.Content(
                number: index + 1, count: layout.rows.count, label: editing ? "" : (option?.label ?? strings.other),
                detail: option?.detail, chosen: chosen, highlighted: state.highlightedRow(item) == index,
                multiSelect: item.multiSelect, isOther: frames.isOther, enabled: true)
            row.configure(content, frames: frames, style: style)
            row.onClick = { [weak self] in self?.handle(.click(row: index)) }
        }
        otherField.font = style.labelFont
        if otherField.stringValue != state.otherDrafts[item.id] ?? "" { otherField.stringValue = state.otherDrafts[item.id] ?? "" }
        let highlighted = state.highlightedRow(item)
        let shown = highlighted < item.options.count ? item.options[highlighted].preview : nil
        previewBox.isHidden = layout.preview == nil
        previewText.isHidden = layout.preview == nil
        previewText.font = style.previewFont
        previewText.stringValue = shown?.text ?? ""
        hint.stringValue = item.multiSelect ? strings.multiHint : strings.hint
        hint.font = style.metaFont
        skipButton.font = style.buttonFont
        submitButton.font = style.buttonFont
        submitButton.isEnabled = state.canSubmit
        setAccessibilityHelp(item.multiSelect ? strings.chooseAny : strings.chooseOne)
    }

    private func configureSummary(_ state: AgentQuestionCardState, _ layout: AgentQuestionCardLayout) {
        var texts: [String] = []
        switch state.question.state {
        case .pending: break
        case .answered(let answer): texts = state.question.summaryLines(answer) + [strings.answeredBy(answer.respondent)]
        case .cancelled: texts = ["\(strings.cancelled) · \(state.question.summary)"]
        }
        while summaryLabels.count < texts.count {
            let label = NSTextField(wrappingLabelWithString: "")
            label.isSelectable = false
            addSubview(label)
            summaryLabels.append(label)
        }
        for (index, label) in summaryLabels.enumerated() {
            label.isHidden = index >= texts.count
            guard index < texts.count else { continue }
            label.stringValue = texts[index]
            let isMeta = layout.mode == .cancelled || index == texts.count - 1
            label.font = isMeta ? style.metaFont : style.summaryFont
            label.maximumNumberOfLines = layout.mode == .cancelled ? 1 : 0
            label.lineBreakMode = layout.mode == .cancelled ? .byTruncatingTail : .byWordWrapping
        }
    }

    public override func layout() {
        super.layout()
        guard let layout = layoutCache else { return }
        layer?.cornerRadius = layout.mode == .pending ? style.cornerRadius : style.size(12)
        chip.frame = layout.chip ?? .zero
        chip.layer?.cornerRadius = (layout.chip?.height ?? 0) / 2
        meta.frame = layout.meta ?? .zero
        prompt.frame = layout.prompt
        for (index, row) in rowViews.enumerated() where index < layout.rows.count {
            row.frame = layout.rows[index].frame
        }
        otherField.frame = layout.otherField ?? .zero
        previewBox.frame = layout.preview ?? .zero
        previewBox.layer?.cornerRadius = style.size(10)
        previewText.frame = (layout.preview ?? .zero).insetBy(dx: style.previewInset, dy: style.previewInset)
        hint.frame = layout.hint ?? .zero
        skipButton.frame = layout.skip ?? .zero
        submitButton.frame = layout.submit ?? .zero
        check.frame = layout.check ?? .zero
        for (index, label) in summaryLabels.enumerated() where index < layout.summary.count {
            label.frame = layout.summary[index]
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            let pending = layoutCache?.mode == .pending
            layer?.backgroundColor = (pending ? Palette.elevatedBackground : Palette.hoverFill).cgColor
            layer?.borderColor = Palette.separator.cgColor
            chip.layer?.backgroundColor = Palette.hoverFill.cgColor
            chip.textColor = Palette.textSecondary
            meta.textColor = Palette.textTertiary
            prompt.textColor = Palette.textPrimary
            previewBox.layer?.backgroundColor = Palette.windowBackground.cgColor
            previewBox.layer?.borderColor = Palette.separator.cgColor
            previewBox.layer?.borderWidth = 1
            previewText.textColor = Palette.textPrimary
            hint.textColor = Palette.textTertiary
            check.contentTintColor = Palette.success
            for (index, label) in summaryLabels.enumerated() {
                let isLast = index == summaryLabels.filter { !$0.isHidden }.count - 1
                label.textColor = isLast || layoutCache?.mode == .cancelled ? Palette.textSecondary : Palette.textPrimary
            }
            skipButton.applyColors()
            submitButton.applyColors()
        }
    }
}
