import AppKit
import CmuxNextDesignTokens
import CmuxNextWakeups

/// The fields a dialog shows rather than asks: a preview, a code to compare, a line to copy, a pairing code with its
/// QR and countdown, work under way, a note. Every one draws its words on the first frame; the pairing code's
/// countdown is the only part that changes by itself (once a second while the card shows).
extension CmuxDialogView {
    func readOnlyFieldViews(_ field: CmuxDialogField, width: CGFloat) -> [NSView] {
        switch field {
        case .preview(let text):
            let preview = label(text, font: Typography.system(.monospaced, size: TypeScale.body), role: .primary, width: width)
            preview.maximumNumberOfLines = 8
            preview.lineBreakMode = .byTruncatingTail
            return [preview]
        case .code(let caption, let text):
            return captioned(caption, codeWell(text, width: width), width: width)
        case .copyLine(let id, let caption, let text, let title):
            let copy = inlineButton(id, title)
            let gap = Metrics.space2
            let well = codeWell(text, width: width - copy.intrinsicContentSize.width - gap, truncates: true)
            let row = NSStackView(views: [well, copy])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = gap
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: width).isActive = true
            return captioned(caption, row, width: width)
        case .pairingCode(let code):
            return [pairingCodeView(code, width: width)]
        case .progress(let text):
            let spinner = StatusIndicatorView.spinner()
            spinner.translatesAutoresizingMaskIntoConstraints = false
            let side = Typography.body.pointSize
            NSLayoutConstraint.activate([spinner.widthAnchor.constraint(equalToConstant: side), spinner.heightAnchor.constraint(equalToConstant: side)])
            spinner.spin(true)
            let words = label(text, font: Typography.body, role: .secondary, width: width - side - Metrics.space2)
            let row = NSStackView(views: [spinner, words])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Metrics.space2
            return [row]
        case .note(let text, let danger):
            return [label(text, font: Typography.caption, role: danger ? .danger : .secondary, width: width)]
        case .steps(let steps):
            let list = NSStackView(views: steps.map { stepRow($0, width: width) })
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = Metrics.space2
            list.setAccessibilityElement(true)
            list.setAccessibilityRole(.list)
            return [list]
        case .text, .choice, .check:
            return []
        }
    }

    /// One step: its state's glyph (the shapes the sidebar draws: idle, spinning, done, waiting, error), its name, then
    /// what it found and its fix in the caption size.
    private func stepRow(_ step: CmuxDialogStep, width: CGFloat) -> NSView {
        let glyph = StatusIndicatorView(frame: .zero)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        let side = Typography.body.pointSize
        NSLayoutConstraint.activate([glyph.widthAnchor.constraint(equalToConstant: side), glyph.heightAnchor.constraint(equalToConstant: side)])
        switch step.state {
        case .pending, .skipped: glyph.configure(.idle)
        case .running: glyph.configure(.busy)
        case .done: glyph.configure(.success)
        case .warning: glyph.configure(.waiting(kind: nil))
        case .failed: glyph.configure(.error)
        }
        let textWidth = width - side - Metrics.space2
        let text = NSStackView(views: [label(step.title, font: Typography.body, role: step.state == .pending || step.state == .skipped ? .secondary : .primary,
                                             width: textWidth)])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.space1
        if !step.detail.isEmpty { text.addArrangedSubview(label(step.detail, font: Typography.caption, role: .secondary, width: textWidth)) }
        if let fix = step.fix { text.addArrangedSubview(label(fix, font: Typography.caption, role: step.state == .failed ? .danger : .secondary, width: textWidth)) }
        let row = NSStackView(views: [glyph, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Metrics.space2
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel(([step.title, step.detail, step.fix ?? ""]).filter { !$0.isEmpty }.joined(separator: ". "))
        return row
    }

    /// A small button inside a field (Copy): pressed by click or by Space once Tab reaches it; it answers nothing.
    private func inlineButton(_ id: String, _ title: String) -> CmuxDialogButtonView {
        let button = CmuxDialogButtonView(CmuxDialogButton(id: id, title: title), hint: nil, target: self, action: #selector(pressed(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("cmux.dialog.action.\(id)")
        focusables.append(button)
        return button
    }

    /// A code to compare (``CmuxDialogField/code(label:text:)``): monospaced digits on an inset well that rounds
    /// as the buttons do, so it reads as one thing to check, apart from the prose around it. `truncates` keeps a
    /// long line (a command) on one line, cut in the middle, as a path is.
    func codeWell(_ text: String, width: CGFloat, truncates: Bool = false, font: NSFont? = nil) -> NSView {
        let inset = CmuxDialogMetrics.codeInset
        let code = label(text, font: font ?? Typography.system(.monospaced, size: TypeScale.body), role: .primary,
                         width: width - inset * 2)
        if truncates {
            code.maximumNumberOfLines = 1
            code.lineBreakMode = .byTruncatingMiddle
            code.themedToolTip = text
        }
        code.identifier = NSUserInterfaceItemIdentifier("cmux.dialog.code")
        // VoiceOver reads the groups, not one long word.
        code.setAccessibilityLabel(text.replacingOccurrences(of: "\n", with: " "))
        let well = CmuxDialogCodeWell()
        well.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(code)
        code.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            code.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: inset),
            code.topAnchor.constraint(equalTo: well.topAnchor, constant: CmuxDialogMetrics.codeVerticalInset),
            well.bottomAnchor.constraint(equalTo: code.bottomAnchor, constant: CmuxDialogMetrics.codeVerticalInset),
            well.widthAnchor.constraint(equalToConstant: width),
        ])
        return well
    }

    /// The pairing code (``CmuxDialogPairingCode``): the code large on its well with Copy, the countdown and the
    /// notes in a column, the QR beside it at the trailing edge.
    private func pairingCodeView(_ code: CmuxDialogPairingCode, width: CGFloat) -> NSView {
        let qrSide = code.image == nil ? 0 : CmuxDialogMetrics.qrSide
        let gap = code.image == nil ? 0 : Metrics.space4
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.space2
        let columnWidth = width - qrSide - gap
        let big = Typography.system(.monospaced, size: TypeScale.heading, weight: TypeScale.emphasis)
        let well = codeWell(code.code, width: columnWidth, font: big)
        well.identifier = NSUserInterfaceItemIdentifier("cmux.dialog.pairingCode")
        column.addArrangedSubview(well)
        if let id = code.copyID { column.addArrangedSubview(inlineButton(id, code.copyTitle)) }
        if let expiresAt = code.expiresAt {
            let line = label("", font: Typography.captionDigits, role: .secondary, width: columnWidth)
            column.addArrangedSubview(CmuxDialogCountdownView(line, until: expiresAt, format: code.expiresFormat))
        }
        for note in code.notes { column.addArrangedSubview(label(note, font: Typography.caption, role: .secondary, width: columnWidth)) }
        guard let data = code.image, let image = NSImage(data: data) else { return column }
        let qr = CmuxDialogQRView(image: image)
        qr.setAccessibilityLabel(code.imageLabel)
        NSLayoutConstraint.activate([qr.widthAnchor.constraint(equalToConstant: qrSide), qr.heightAnchor.constraint(equalToConstant: qrSide)])
        let row = NSStackView(views: [column, qr])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = gap
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }
}

extension CmuxDialogMetrics {
    /// A pairing code's QR: large enough for a phone's camera across a desk.
    static var qrSide: CGFloat { 120 * Typography.userScale }
}

/// A pairing code's QR on a white plate (a QR needs its quiet zone light in every theme), rounded as the code's well.
@MainActor
final class CmuxDialogQRView: NSImageView {
    convenience init(image: NSImage) {
        self.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyUpOrDown
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = CmuxDialogMetrics.buttonCornerRadius
        layer?.cornerCurve = .continuous
        layer?.magnificationFilter = .nearest
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
}

/// The countdown of a pairing code ("Expires in 9:41"), in the danger ink in its last minute. It counts only while
/// it is in a window: one deadline at a time to the next whole second (``DemandTimer``), never a repeating timer,
/// and none once the card is gone.
@MainActor
final class CmuxDialogCountdownView: NSView {
    private let line: ThemedLabel
    private let until: Date
    private let format: String
    private let timer = DemandTimer(owner: "dialog.pairingCode.countdown")
    var now: () -> Date = Date.init

    init(_ line: ThemedLabel, until: Date, format: String) {
        self.line = line
        self.until = until
        self.format = format
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        line.translatesAutoresizingMaskIntoConstraints = false
        line.setAccessibilityRole(.staticText)
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor), line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        draw()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { timer.cancel() } else { tick() }
    }

    /// The words for now: the first frame shows them before any deadline fires.
    private func draw() {
        let at = now()
        line.stringValue = String(format: format, CmuxDialogPairingCode.clock(until: until, now: at))
        line.themeColor = until.timeIntervalSince(at) < 60 ? { CmuxDialogView.dangerInk() } : { Palette.sheetText(.secondary) }
    }

    private func tick() {
        draw()
        let left = until.timeIntervalSince(now())
        guard window != nil, left > 0 else { return timer.cancel() }
        // To the next whole second of the count, so the clock never skips a digit.
        let fraction = left - left.rounded(.down)
        let delay = fraction > 0.001 ? fraction : 1
        timer.schedule(after: .milliseconds(Int((delay * 1000).rounded(.up)))) { @MainActor [weak self] in
            self?.tick()
        }
    }
}

/// The inset well under a dialog's code (``CmuxDialogField/code(label:text:)``): a faint fill of the text's own ink
/// with a hairline edge, rounded as the dialog's buttons are, so it sits on any glass, light or dark, and under
/// Increase Contrast its edge reads as a line.
@MainActor
final class CmuxDialogCodeWell: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        performWithTheme {
            let ink = Palette.sheetText(.primary)
            layer?.cornerRadius = CmuxDialogMetrics.buttonCornerRadius
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = ink.withAlphaComponent(CmuxDialogMetrics.codeWellFill).cgColor
            layer?.borderWidth = contrast ? 1 : CmuxDialogMetrics.hairline(in: window)
            layer?.borderColor = ink.withAlphaComponent(contrast ? 0.5 : CmuxDialogMetrics.codeWellEdge).cgColor
        }
    }
}
