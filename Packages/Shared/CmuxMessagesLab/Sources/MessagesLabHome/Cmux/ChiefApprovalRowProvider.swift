import AppKit

/// The Chief's approval request (`ChiefRows.approvalKind`).
///
/// Pending, it is an incoming Messages bubble: the transcript draws the grey bubble
/// and its tail in the row bitmap and this view lies on the bubble body:
///
///     Chief wants to run                              12 pt secondary caption
///     ┌────────────────────────────────────┐
///     │ cmux tree --all 2>&1 | head -100   │          12 pt mono in Markdown's code-block fill
///     └────────────────────────────────────┘
///     Not in your allowed commands: cmux tree         11 pt tertiary reason (commands only)
///                          Deny  ( Allow ⏎ ) (⌄)      plain, accent, "Always Allow …" menu
///
/// The command breaks only at spaces and after a "/" (`ChiefRows.wrappable`), never inside a
/// flag; the reason line follows Cursor's "Not in allowlist: node".
///
/// Answered, it collapses to a one-line receipt on the Chief's side, no bubble
/// (10 pt secondary): "✓ Allowed: cmux tree --all" or "✕ Denied".
///
/// Keys: Return picks the tinted option and Esc the refusing one while the card has
/// the focus, and from the compose field while it is empty and this card waits
/// (`ChatController.answerPendingApproval`). References (cmux-design-references):
/// Cursor's command approval (cursor/live/approval-command-pending.png: the command in
/// a mono block, quiet Skip, filled Run ⏎, the run-mode chevron), Codex's computer-use
/// approval (codex/web/computer-use-approval.webp: caption, Cancel Esc, Allow ⏎) and
/// T3 Code's Decline and Approve with the "Resolve this approval request" composer
/// (t3-code/live/approval-command-and-thread-details.png).
final class ChiefApprovalRowProvider: TranscriptCustomRowProvider {
    static let shared = ChiefApprovalRowProvider()

    let kind = ChiefRows.approvalKind
    var measuresOffMain: Bool { true }

    func layout(for part: CustomPart) -> CustomRowLayout {
        part.decode(ChiefRows.Approval.self)?.isPending == false ? .fullWidth : .bubbleIncoming
    }

    // Card metrics (points): the bubble's own padding.
    static let padX: CGFloat = Fixture.bubblePadX
    static let padTop: CGFloat = 8
    static let padBottom: CGFloat = 9
    static let captionHeight: CGFloat = 15
    static let captionGap: CGFloat = 5
    static let blockPadX: CGFloat = 8
    static let blockPadY: CGFloat = 6
    static let blockRadius: CGFloat = 6
    static let buttonsGap: CGFloat = 10
    static let buttonHeight: CGFloat = 26
    static let buttonSpacing: CGFloat = 6
    static let chevronWidth: CGFloat = 26
    static let receiptHeight: CGFloat = 18
    static let reasonGap: CGFloat = 5
    static let reasonHeight: CGFloat = 14

    static let captionFont = HomeFonts.system(ofSize: 12)
    static let codeFont = HomeFonts.monospaced(ofSize: 12)
    static let buttonFont = HomeFonts.system(ofSize: 13, weight: .medium)
    static let prominentFont = HomeFonts.system(ofSize: 13, weight: .semibold)
    static let receiptFont = HomeFonts.system(ofSize: 10, weight: .medium)
    static let receiptCode = HomeFonts.monospaced(ofSize: 10)
    static let reasonFont = HomeFonts.system(ofSize: 11)

    /// The reason line under a command (nil for other prompts).
    static func reason(_ a: ChiefRows.Approval) -> String? { a.command.flatMap(ChiefRows.reason(for:)) }

    // MARK: Text

    /// The card's body: the command (mono, in a block) or the prompt (body text, backtick spans mono).
    static func body(_ a: ChiefRows.Approval, color: NSColor? = nil) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        // A long command breaks between its words (flags, paths); a word longer than the line breaks inside.
        style.lineBreakMode = .byWordWrapping
        func attrs(_ font: NSFont) -> [NSAttributedString.Key: Any] {
            var out: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
            if let color { out[.foregroundColor] = color }
            return out
        }
        if let command = a.command {
            // A shell prompt makes the approval block read as an executable command while
            // keeping the command itself selectable and monospaced.
            return NSAttributedString(string: "$ " + ChiefRows.wrappable(command), attributes: attrs(codeFont))
        }
        let out = NSMutableAttributedString()
        for (text, code) in ChiefRows.promptRuns(ChiefRows.displayPrompt(a.prompt)) {
            out.append(NSAttributedString(string: text, attributes: attrs(code ? HomeFonts.code : Fixture.bodyFont)))
        }
        return out
    }

    static func textSize(_ s: NSAttributedString, width: CGFloat) -> CGSize {
        let r = s.boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// The buttons' widths (left to right) and the row's total.
    static func buttonWidths(_ a: ChiefRows.Approval) -> [CGFloat] {
        var out = a.buttonOrder.map { option -> CGFloat in
            let prominent = option == a.prominent
            let title = NSAttributedString(string: ChiefRows.buttonTitle(option), attributes: [.font: prominent ? prominentFont : buttonFont])
            // The tinted capsule carries a return glyph; the others are plain text with a hover capsule.
            return ceil(title.size().width) + (prominent ? 24 + 16 : 20)
        }
        if a.alwaysAllowPrefix != nil { out.append(chevronWidth) }
        return out
    }

    static func buttonsWidth(_ a: ChiefRows.Approval) -> CGFloat {
        let w = buttonWidths(a)
        return w.reduce(0, +) + CGFloat(max(0, w.count - 1)) * buttonSpacing
    }

    /// The pending card's bubble size for at most `maxWidth`, or the receipt's (full width).
    static func size(_ a: ChiefRows.Approval, maxWidth: CGFloat) -> CGSize {
        guard a.isPending else { return CGSize(width: maxWidth, height: receiptHeight) }
        let inner = maxWidth - 2 * padX
        let caption = NSAttributedString(string: ChiefRows.caption(a), attributes: [.font: captionFont])
        let boxed = a.command != nil
        let bodyInset = boxed ? 2 * blockPadX : 0
        let natural = textSize(body(a), width: inner - bodyInset)
        let width = min(inner, max(ceil(caption.size().width), natural.width + bodyInset, buttonsWidth(a), 180))
        let text = textSize(body(a), width: width - bodyInset)
        let bodyHeight = text.height + (boxed ? 2 * blockPadY : 0)
        let reasonSpace = reason(a) == nil ? 0 : reasonGap + reasonHeight
        let height = padTop + captionHeight + captionGap + bodyHeight + reasonSpace + buttonsGap + buttonHeight + padBottom
        return CGSize(width: width + 2 * padX, height: height)
    }

    // MARK: Provider

    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize {
        guard let a = part.decode(ChiefRows.Approval.self) else { return CGSize(width: 200, height: 36) }
        return Self.size(a, maxWidth: maxWidth)
    }

    func estimate(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { measure(part, maxWidth: maxWidth) }

    func makeView() -> CustomRowPlatformView { ChiefApprovalCardView() }

    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {
        guard let v = view as? ChiefApprovalCardView, let a = part.decode(ChiefRows.Approval.self) else { return }
        v.show(a, context: context)
    }

    func prepareForReuse(_ view: CustomRowPlatformView) { (view as? ChiefApprovalCardView)?.reset() }

    func handleKey(_ key: CustomRowKey, view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) -> Bool {
        guard let v = view as? ChiefApprovalCardView, let a = part.decode(ChiefRows.Approval.self), a.isPending else { return false }
        switch key {
        case .enter: if let p = a.prominent { v.answer(p) }
        case .escape:
            guard let r = a.refusal else { return false }
            v.answer(r)
        default: return false
        }
        return true
    }

    func plainText(_ part: CustomPart) -> String? {
        guard let a = part.decode(ChiefRows.Approval.self) else { return nil }
        guard let decided = a.decided else { return ChiefRows.displayPrompt(a.prompt) }
        return ChiefRows.decidedLabel(decided, command: a.command)
    }
}

/// The card on the bubble body (pending) or the receipt line (answered).
final class ChiefApprovalCardView: NSView {
    private var approval: ChiefRows.Approval?
    private var context: CustomRowContext?
    private var buttons: [ChiefOptionButton] = []
    private var chevron: ChiefOptionButton?
    /// The request answered from this view, waiting for the owner's echo.
    private var sentRequest: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription(CmuxStrings.approvalRole)
        setAccessibilityIdentifier("ChiefApprovalCard")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func reset() {
        approval = nil
        context = nil
        sentRequest = nil
        removeButtons()
    }

    private func removeButtons() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        chevron?.removeFromSuperview()
        chevron = nil
    }

    func show(_ a: ChiefRows.Approval, context: CustomRowContext) {
        if approval?.request != a.request { sentRequest = nil }
        let rebuilt = approval?.request != a.request || approval?.options != a.options || approval?.isPending != a.isPending
        approval = a
        self.context = context
        setAccessibilityLabel(a.isPending ? ChiefRows.caption(a) + ": " + (a.command ?? ChiefRows.displayPrompt(a.prompt))
                                          : a.decided.map { ChiefRows.decidedLabel($0, command: a.command) })
        setAccessibilityHelp(a.isPending ? ChiefApprovalRowProvider.reason(a) : nil)
        setAccessibilityRole(a.isPending ? .group : .staticText)
        toolTip = a.isPending ? nil : ChiefRows.displayPrompt(a.prompt)
        if rebuilt {
            removeButtons()
            if a.isPending {
                buttons = a.buttonOrder.map { option in
                    let b = ChiefOptionButton(option: option, style: option == a.prominent ? .prominent : .plain)
                    b.target = self
                    b.action = #selector(choose(_:))
                    let title = ChiefRows.buttonTitle(option)
                    if let command = a.command, ChiefRows.grants(option) {
                        b.setAccessibilityLabel(CmuxStrings.approvalAllowRunning(command))
                    } else if let command = a.command, ChiefRows.refuses(option) {
                        b.setAccessibilityLabel(CmuxStrings.approvalDenyRunning(command))
                    }
                    if option == a.prominent { b.toolTip = title + " (" + CmuxStrings.approvalProminentHelp + ")" }
                    if option == a.refusal { b.toolTip = title + " (" + CmuxStrings.approvalRefusalHelp + ")" }
                    addSubview(b)
                    return b
                }
                if a.alwaysAllowPrefix != nil {
                    let c = ChiefOptionButton(option: "", style: .chevron)
                    c.target = self
                    c.action = #selector(showMore(_:))
                    // The chevron is the approval's "Always Allow" action, rather than a
                    // generic overflow menu. Name the rule in AX so VoiceOver users can
                    // choose the same scoped rule that the tooltip exposes visually.
                    c.setAccessibilityLabel(a.alwaysAllowPrefix.map(CmuxStrings.approvalAlwaysAllow)
                                            ?? CmuxStrings.approvalMoreOptions)
                    c.toolTip = a.alwaysAllowPrefix.map(CmuxStrings.approvalAlwaysAllow)
                    c.setAccessibilityIdentifier("ChiefApprovalOption.More")
                    addSubview(c)
                    chevron = c
                }
            }
        }
        for b in buttons + [chevron].compactMap({ $0 }) {
            b.isEnabled = sentRequest == nil
        }
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Layout and drawing

    override func layout() {
        super.layout()
        guard let a = approval, a.isPending else { return }
        let p = ChiefApprovalRowProvider.self
        let widths = p.buttonWidths(a)
        let controls: [ChiefOptionButton] = buttons + [chevron].compactMap { $0 }
        let y = bounds.height - p.padBottom - p.buttonHeight
        // Right-aligned, the tinted option nearest the edge (its chevron last).
        var x = bounds.width - p.padX - p.buttonsWidth(a)
        for (b, w) in zip(controls, widths) {
            b.frame = NSRect(x: x.rounded(), y: y, width: w, height: p.buttonHeight)
            x += w + p.buttonSpacing
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let a = approval else { return }
        guard a.isPending else { drawReceipt(a); return }
        let p = ChiefApprovalRowProvider.self
        let inner = bounds.width - 2 * p.padX
        let caption = NSAttributedString(string: ChiefRows.caption(a),
                                         attributes: [.font: p.captionFont, .foregroundColor: Fixture.secondaryText])
        caption.draw(at: NSPoint(x: p.padX, y: p.padTop))
        let top = p.padTop + p.captionHeight + p.captionGap
        let boxed = a.command != nil
        let inset = boxed ? p.blockPadX : 0
        let body = ChiefApprovalRowProvider.body(a, color: Fixture.incomingText)
        let size = ChiefApprovalRowProvider.textSize(body, width: inner - 2 * inset)
        if boxed, let ctx = NSGraphicsContext.current?.cgContext {
            // Markdown's code-block fill on the grey bubble (MarkdownDraw: black 0.24 dark, 0.06 light).
            let block = CGRect(x: p.padX, y: top, width: inner, height: size.height + 2 * p.blockPadY)
            ctx.setFillColor(NSColor(white: 0, alpha: Fixture.lightAppearance ? 0.06 : 0.24).cgColor)
            ctx.addPath(CGPath(roundedRect: block, cornerWidth: p.blockRadius, cornerHeight: p.blockRadius, transform: nil))
            ctx.fillPath()
        }
        body.draw(with: NSRect(x: p.padX + inset, y: top + (boxed ? p.blockPadY : 0), width: inner - 2 * inset, height: size.height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        if let reason = p.reason(a) {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let line = NSAttributedString(string: reason, attributes: [
                .font: p.reasonFont, .foregroundColor: Fixture.secondaryText.withAlphaComponent(0.7), .paragraphStyle: style,
            ])
            let y = top + size.height + (boxed ? 2 * p.blockPadY : 0) + p.reasonGap
            line.draw(with: NSRect(x: p.padX, y: y, width: inner, height: p.reasonHeight), options: [.usesLineFragmentOrigin])
        }
    }

    /// "✓ Allowed: cmux tree --all" (green check) or "✕ Denied" (secondary), 10 pt, the tool rows' column.
    private func drawReceipt(_ a: ChiefRows.Approval) {
        guard let decided = a.decided else { return }
        let p = ChiefApprovalRowProvider.self
        let granted = ChiefRows.grants(decided)
        let mid = p.receiptHeight / 2
        let name = granted ? "checkmark.circle.fill" : ChiefRows.refuses(decided) ? "xmark.circle.fill" : "circle.fill"
        let tint: NSColor = granted ? .systemGreen : Fixture.secondaryText
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium).applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let s = img.size
            img.draw(in: NSRect(x: (ChiefToolRowView.glyphX + (14 - s.width) / 2).rounded(), y: (mid - s.height / 2).rounded(),
                                width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let plain: [NSAttributedString.Key: Any] = [.font: p.receiptFont, .foregroundColor: Fixture.secondaryText]
        let text = NSMutableAttributedString()
        let limit = min(bounds.width, ChiefToolRowView.maxLineWidth) - ChiefToolRowView.textX
        if granted, let command = a.command {
            // "Allowed: %@" with the command monospaced and middle-truncated to the line.
            let token = "\u{1}"
            let frame = CmuxStrings.approvalAllowedCommand(token).components(separatedBy: token)
            let before = frame.first ?? "", after = frame.dropFirst().joined()
            func build(_ shown: String) -> NSAttributedString {
                let s = NSMutableAttributedString(string: before, attributes: plain)
                s.append(NSAttributedString(string: shown, attributes: [.font: p.receiptCode, .foregroundColor: Fixture.secondaryText]))
                s.append(NSAttributedString(string: after, attributes: plain))
                return s
            }
            text.append(ChiefToolRowView.fitting(command, width: limit, build: build))
        } else {
            text.append(NSAttributedString(string: ChiefRows.decidedLabel(decided, command: a.command), attributes: plain))
        }
        let ts = text.size()
        text.draw(at: NSPoint(x: ChiefToolRowView.textX, y: (mid - ts.height / 2).rounded()))
    }

    // MARK: Actions

    @objc private func choose(_ sender: ChiefOptionButton) { answer(sender.option) }

    @objc private func showMore(_ sender: ChiefOptionButton) {
        guard let a = approval, let prefix = a.alwaysAllowPrefix else { return }
        let menu = NSMenu()
        let item = NSMenuItem(title: CmuxStrings.approvalAlwaysAllow(prefix), action: #selector(alwaysAllow(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func alwaysAllow(_ sender: NSMenuItem) {
        guard let p = approval?.prominent else { return }
        answer(p, always: true)
    }

    /// Sends `option` for this card's request (a click, Return or Esc on the card, the field's keys).
    func answer(_ option: String, always: Bool = false) {
        guard let a = approval, a.isPending, sentRequest == nil, let ref = context?.ref, let intents = hostIntents else { return }
        sentRequest = a.request
        for b in buttons + [chevron].compactMap({ $0 }) { b.isEnabled = false }
        let request = a.request
        intents.answerApproval(ref, choice: option, always: always) { [weak self] ok in
            // Refused (offline, decided elsewhere): the buttons come back for another try.
            guard let self, !ok, self.sentRequest == request else { return }
            self.sentRequest = nil
            for b in self.buttons + [self.chevron].compactMap({ $0 }) { b.isEnabled = true }
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

/// An approval button: the tinted capsule with a return glyph (the granting option),
/// plain text with a hover capsule (the others), or the small chevron for more options.
final class ChiefOptionButton: NSButton {
    /// `quiet`: a filled grey capsule with a centred title (a system row's action, "Try Again").
    enum Style { case prominent, plain, chevron, quiet }

    let option: String
    let style: Style
    private var hovering = false
    private var tracking: NSTrackingArea?
    private let glyph = CALayer()

    init(option: String, style: Style) {
        self.option = option
        self.style = style
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = ChiefApprovalRowProvider.buttonHeight / 2
        layer?.cornerCurve = .continuous
        setButtonType(.momentaryChange)
        focusRingType = .none
        imagePosition = .noImage
        layer?.addSublayer(glyph)
        if style != .chevron {
            let title = ChiefRows.buttonTitle(option)
            self.title = title
            setAccessibilityLabel(title)
            setAccessibilityIdentifier("ChiefApprovalOption.\(option)")
        }
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool { didSet { restyle() } }

    override func layout() {
        super.layout()
        layoutGlyph()
    }

    private func layoutGlyph() {
        guard let image = glyph.contents as? NSImage else { return }
        let s = image.size
        let x = style == .chevron ? (bounds.width - s.width) / 2 : bounds.width - 12 - s.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glyph.frame = CGRect(x: x.rounded(), y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height)
        CATransaction.commit()
    }

    func restyle() {
        let light = Fixture.lightAppearance
        let quiet = light ? NSColor(white: 0, alpha: 0.07) : NSColor(white: 1, alpha: 0.12)
        let fill: NSColor
        let ink: NSColor
        switch style {
        case .prominent:
            // The accent fill and its text, as my sent bubbles draw them (also in an inactive
            // window: the transcript's sends stay tinted, so the default button does too).
            fill = Fixture.outgoing
            ink = Fixture.outgoingText
        case .plain:
            fill = hovering || isHighlighted ? quiet : .clear
            ink = Fixture.incomingText
        case .chevron:
            fill = quiet
            ink = Fixture.incomingText
        case .quiet:
            fill = quiet.withAlphaComponent(quiet.alphaComponent * (hovering || isHighlighted ? 1.6 : 1))
            ink = Fixture.incomingText
        }
        let pressed = isHighlighted && style != .plain
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = fill.withAlphaComponent(fill.alphaComponent * (pressed ? 0.75 : 1)).cgColor
        CATransaction.commit()
        alphaValue = isEnabled ? 1 : 0.45
        let symbol: (String, CGFloat)? = style == .prominent ? ("return", 10) : style == .chevron ? ("chevron.down", 9) : nil
        if let (name, size) = symbol {
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [ink.withAlphaComponent(style == .prominent ? 0.75 : 0.85)]))
            glyph.contents = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            glyph.contentsScale = window?.backingScaleFactor ?? 2
            layoutGlyph()
        }
        guard style != .chevron else { attributedTitle = NSAttributedString(string: ""); return }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byClipping
        let font = style == .prominent ? ChiefApprovalRowProvider.prominentFont : ChiefApprovalRowProvider.buttonFont
        attributedTitle = NSAttributedString(string: ChiefRows.buttonTitle(option), attributes: [
            .font: font, .foregroundColor: ink, .paragraphStyle: para,
        ])
        needsDisplay = true
    }

    /// Drawn here, not by the cell: the prominent capsule's title sits left of its return glyph.
    override func draw(_ dirtyRect: NSRect) {
        guard style != .chevron else { return }
        let t = attributedTitle
        let s = t.size()
        let x: CGFloat = style == .prominent ? 12 : (bounds.width - s.width) / 2
        t.draw(at: NSPoint(x: x.rounded(), y: ((bounds.height - s.height) / 2).rounded()))
    }

    override var isFlipped: Bool { true }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        restyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; restyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; restyle() }
}
