public import AppKit
import CmuxNextDesign
import Observation

/// The Pair Another Machine card's content (AppKit, plans/cmux-next/no-swiftui-DESIGN.md): the code
/// large with its QR, the `cmux pair` line and the install line with their Copy buttons and the
/// countdown; then, once a machine used the code, Add Server's facts, four words and name, with
/// Confirm. It draws the model again whenever a value it read changes (Observation); the countdown
/// is its own label, so a tick redraws one label.
@MainActor
public final class PairInviteView: NSView {
    public let model: PairInviteModel
    /// The card should close (Done, Cancel).
    public var onClose: () -> Void = {}
    /// The fitting size changed (the machine arrived, an error showed).
    public var onResize: (NSSize) -> Void = { _ in }

    static let width: CGFloat = 460
    static let qrSide: CGFloat = 132
    /// The code is read across a desk or aloud, like the QR beside it: half again the heading step.
    static let codeSize: CGFloat = TypeScale.heading * 1.5

    private let stack = NSStackView()
    private var actions: [PairInviteAction] = []
    /// The Confirm (or Try Again) button now shown: the panel reads the person's click on it.
    private(set) weak var confirmButton: NSControl?
    /// The Name field outlives a redraw, so what the person typed stays; it is read only on Confirm.
    let nameField = NSTextField()
    private var nameFieldCode: String?

    public init(model: PairInviteModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 240))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("cmux.pairInvite")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space4
        stack.edgeInsets = NSEdgeInsets(top: Metrics.space6, left: Metrics.space6, bottom: Metrics.space5, right: Metrics.space6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        nameField.font = Typography.body
        nameField.focusRingType = .none
        nameField.setAccessibilityIdentifier("cmux.pairInvite.name")
        nameField.setAccessibilityLabel(ServerStrings.name)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// SECURITY: Confirm, from the person's own click on it (``PairInviteCardPanel`` calls this).
    func confirm() {
        model.confirm(name: nameField.stringValue)
    }

    private func render() {
        withObservationTracking { build() } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
        layoutSubtreeIfNeeded()
        onResize(fittingSize)
    }

    private func build() {
        actions.removeAll()
        confirmButton = nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width = Self.width - 2 * Metrics.space6
        let step = model.step
        switch step {
        case .minting:
            header(PairInviteStrings.title, width: width)
            stack.addArrangedSubview(waitingRow(PairInviteStrings.minting, width: width))
        case let .showing(invite):
            header(PairInviteStrings.title, width: width)
            stack.addArrangedSubview(label(PairInviteStrings.help, font: Typography.body, color: Palette.textSecondary, width: width))
            buildInvite(invite, width: width)
        case .lookingUp:
            header(PairInviteStrings.arrived, width: width)
            stack.addArrangedSubview(waitingRow(PairInviteStrings.lookingUp, width: width))
        case let .review(_, candidate), let .approving(_, candidate):
            buildReview(candidate, width: width)
        case let .approveFailed(_, candidate, reject):
            buildReview(candidate, width: width)
            stack.addArrangedSubview(label(reject, font: Typography.body, color: Palette.danger, width: width))
        case let .paired(name):
            header(PairInviteStrings.paired(name), width: width)
            stack.addArrangedSubview(label(PairInviteStrings.pairedDetail, font: Typography.body, color: Palette.textSecondary, width: width))
        case .voided:
            header(PairInviteStrings.title, width: width)
            stack.addArrangedSubview(label(PairInviteStrings.voided, font: Typography.body, color: Palette.danger, width: width))
        case .expired:
            header(PairInviteStrings.title, width: width)
            stack.addArrangedSubview(label(PairInviteStrings.expired, font: Typography.body, color: Palette.textPrimary, width: width))
        case .lost:
            header(PairInviteStrings.title, width: width)
            stack.addArrangedSubview(label(PairInviteStrings.lost, font: Typography.body, color: Palette.textPrimary, width: width))
        case .signedOut:
            header(PairInviteStrings.title, width: width)
            stack.addArrangedSubview(label(PairInviteStrings.signedOut, font: Typography.body, color: Palette.textPrimary, width: width))
        case let .failed(text):
            header(PairInviteStrings.title, width: width)
            stack.addArrangedSubview(label(text, font: Typography.body, color: Palette.danger, width: width))
        }
        stack.addArrangedSubview(footer(step, width: width))
    }

    private func header(_ text: String, width: CGFloat) {
        let field = label(text, font: Typography.system(size: TypeScale.title, weight: TypeScale.emphasis), color: Palette.textPrimary, width: width)
        field.setAccessibilityRole(.staticText)
        field.setAccessibilityLabel(text)
        stack.addArrangedSubview(field)
    }

    // MARK: - The invite

    private func buildInvite(_ invite: PairInvite, width: CGFloat) {
        // The code large with Copy Code under it, the QR beside it.
        let codeColumn = NSStackView()
        codeColumn.orientation = .vertical
        codeColumn.alignment = .leading
        codeColumn.spacing = Metrics.space3
        let code = NSTextField(labelWithString: invite.displayCode)
        code.font = Typography.system(.monospaced, size: Self.codeSize, weight: TypeScale.emphasis)
        code.textColor = Palette.textPrimary
        code.isSelectable = true
        code.focusRingType = .none
        code.setAccessibilityIdentifier("cmux.pairInvite.code")
        codeColumn.addArrangedSubview(code)
        codeColumn.addArrangedSubview(button(.copyCode, key: nil, id: "cmux.pairInvite.button.copyCode"))
        let countdown = NSStackView()
        countdown.spacing = Metrics.space2
        countdown.addArrangedSubview(PairInviteCountdownLabel(model: model))
        countdown.addArrangedSubview(label("· " + PairInviteStrings.once, font: Typography.caption, color: Palette.textTertiary, width: nil))
        codeColumn.addArrangedSubview(countdown)
        codeColumn.addArrangedSubview(label(PairInviteStrings.scan, font: Typography.caption, color: Palette.textTertiary,
                                            width: width - Self.qrSide - Metrics.space4))
        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = Metrics.space4
        top.addArrangedSubview(codeColumn)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        top.addArrangedSubview(spacer)
        top.addArrangedSubview(qr(invite.qrPayload))
        top.translatesAutoresizingMaskIntoConstraints = false
        top.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(top)
        stack.addArrangedSubview(lineRow(invite.line, action: .copyLine, id: "line", width: width))
        stack.addArrangedSubview(label(PairInviteStrings.installHelp, font: Typography.caption, color: Palette.textSecondary, width: width))
        stack.addArrangedSubview(lineRow(invite.installLine, action: .copyInstallLine, id: "installLine", width: width))
        stack.addArrangedSubview(waitingRow(PairInviteStrings.waiting, width: width))
    }

    /// A QR on a white tile: always dark on white, whatever the theme, so every camera reads it.
    private func qr(_ payload: String) -> NSView {
        let view = NSImageView()
        if let image = QRCode.image(for: payload) {
            view.image = NSImage(cgImage: image, size: NSSize(width: Self.qrSide, height: Self.qrSide))
        }
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.magnificationFilter = .nearest
        view.layer?.backgroundColor = NSColor.white.cgColor
        view.layer?.cornerRadius = 8
        view.layer?.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: Self.qrSide).isActive = true
        view.heightAnchor.constraint(equalToConstant: Self.qrSide).isActive = true
        view.setAccessibilityIdentifier("cmux.pairInvite.qr")
        view.setAccessibilityLabel(PairInviteStrings.scan)
        return view
    }

    /// A line in the monospaced box Add Device uses, with its Copy button beside it.
    private func lineRow(_ line: String, action: PairInviteAction, id: String, width: CGFloat) -> NSView {
        let copy = button(action, key: nil, id: "cmux.pairInvite.button.\(id)")
        let field = NSTextField(wrappingLabelWithString: line)
        field.isSelectable = true
        field.focusRingType = .none
        field.font = Typography.system(.monospaced, size: TypeScale.detail)
        field.textColor = Palette.textPrimary
        field.setAccessibilityIdentifier("cmux.pairInvite.\(id)")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let box = NSStackView()
        box.orientation = .horizontal
        box.alignment = .centerY
        box.spacing = Metrics.space2
        box.edgeInsets = NSEdgeInsets(top: Metrics.space2, left: Metrics.space3, bottom: Metrics.space2, right: Metrics.space2)
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = Palette.textPrimary.withAlphaComponent(0.06).cgColor
        box.addArrangedSubview(field)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        box.addArrangedSubview(spacer)
        box.addArrangedSubview(copy)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.preferredMaxLayoutWidth = width - 2 * Metrics.space3 - copy.fittingSize.width - Metrics.space2
        return box
    }

    // MARK: - The arrived machine (Add Server's facts and words)

    private func buildReview(_ candidate: PairingCandidate, width: CGFloat) {
        header(PairInviteStrings.arrived, width: width)
        stack.addArrangedSubview(facts(candidate, width: width))
        stack.addArrangedSubview(label(ServerStrings.wordsQuestion, font: Typography.bodyEmphasized, color: Palette.textPrimary, width: width))
        stack.addArrangedSubview(words(candidate.words, width: width))
        stack.addArrangedSubview(label(ServerStrings.wordsWarning, font: Typography.caption, color: Palette.textTertiary, width: width))
        if nameFieldCode != candidate.code {
            nameFieldCode = candidate.code
            nameField.stringValue = candidate.name
        }
        nameField.placeholderString = candidate.name
        let nameRow = NSStackView()
        nameRow.orientation = .horizontal
        nameRow.alignment = .firstBaseline
        nameRow.spacing = Metrics.space3
        nameRow.addArrangedSubview(label(ServerStrings.name, font: Typography.body, color: Palette.textSecondary, width: nil))
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameRow.addArrangedSubview(nameField)
        nameRow.translatesAutoresizingMaskIntoConstraints = false
        nameRow.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(nameRow)
        let chief = NSButton(checkboxWithTitle: ServerStrings.runChief, target: self, action: #selector(runChiefChanged(_:)))
        chief.state = model.approver.approval.runChief ? .on : .off
        chief.font = Typography.body
        chief.setAccessibilityIdentifier("cmux.pairInvite.runChief")
        stack.addArrangedSubview(chief)
        stack.addArrangedSubview(label(PairInviteStrings.confirmNote, font: Typography.caption, color: Palette.textTertiary, width: width))
    }

    private func facts(_ candidate: PairingCandidate, width: CGFloat) -> NSView {
        var parts = [candidate.os, candidate.version].filter { !$0.isEmpty }
        if let region = candidate.region {
            parts.append(Locale.current.localizedString(forRegionCode: region) ?? region)
        }
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.space1
        column.edgeInsets = NSEdgeInsets(top: Metrics.space3, left: Metrics.space3, bottom: Metrics.space3, right: Metrics.space3)
        column.wantsLayer = true
        column.layer?.cornerRadius = 8
        column.layer?.backgroundColor = Palette.textPrimary.withAlphaComponent(0.06).cgColor
        column.addArrangedSubview(label(candidate.name, font: Typography.bodyEmphasized, color: Palette.textPrimary, width: width - 2 * Metrics.space3))
        column.addArrangedSubview(label(parts.joined(separator: " · "), font: Typography.caption, color: Palette.textSecondary,
                                        width: width - 2 * Metrics.space3))
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: width).isActive = true
        column.setAccessibilityIdentifier("cmux.pairInvite.facts")
        return column
    }

    /// The four fingerprint words, two by two, numbered (Add Server's grid).
    private func words(_ words: [String], width: CGFloat) -> NSView {
        let cells = words.enumerated().map { index, word -> NSView in
            let cell = NSStackView()
            cell.spacing = Metrics.space2
            cell.alignment = .firstBaseline
            cell.edgeInsets = NSEdgeInsets(top: Metrics.space2, left: Metrics.space3, bottom: Metrics.space2, right: Metrics.space3)
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 8
            cell.layer?.backgroundColor = Palette.textPrimary.withAlphaComponent(0.06).cgColor
            cell.addArrangedSubview(label("\(index + 1)", font: Typography.caption, color: Palette.textTertiary, width: nil))
            cell.addArrangedSubview(label(word, font: Typography.system(size: TypeScale.field, weight: TypeScale.emphasis), color: Palette.textPrimary, width: nil))
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            cell.addArrangedSubview(spacer)
            cell.translatesAutoresizingMaskIntoConstraints = false
            cell.widthAnchor.constraint(equalToConstant: (width - Metrics.space2) / 2).isActive = true
            return cell
        }
        let rows = stride(from: 0, to: cells.count, by: 2).map { Array(cells[$0..<min($0 + 2, cells.count)]) }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = Metrics.space2
        grid.columnSpacing = Metrics.space2
        grid.setAccessibilityIdentifier("cmux.pairInvite.words")
        grid.setAccessibilityElement(true)
        grid.setAccessibilityLabel(words.joined(separator: ", "))
        return grid
    }

    @objc private func runChiefChanged(_ sender: NSButton) {
        model.approver.approval.runChief = sender.state == .on
    }

    // MARK: - Controls

    private func footer(_ step: PairInviteModel.Step, width: CGFloat) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = Metrics.space2
        if case .approving = step { row.addArrangedSubview(StatusIndicatorView.spinner()) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        for item in model.buttons {
            let view = button(item.action, key: item.key, id: "cmux.pairInvite.button.\(Self.name(item.action))")
            if let control = view as? NSControl {
                control.isEnabled = model.isEnabled(item.action)
                if item.action.isPersonClickOnly { confirmButton = control }
            }
            row.addArrangedSubview(view)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    static func name(_ action: PairInviteAction) -> String {
        switch action {
        case .copyCode: "copyCode"
        case .copyLine: "copyLine"
        case .copyInstallLine: "copyInstallLine"
        case .confirm: "confirm"
        case .retry: "retry"
        case .newCode: "newCode"
        case .done: "done"
        case .cancel: "cancel"
        }
    }

    private func button(_ action: PairInviteAction, key: PairInviteButton.Key?, id: String) -> NSView {
        let role: CmuxDialogButton.Role = switch key {
        case .return: .default
        case .escape: .cancel
        case nil: .normal
        }
        let spec = CmuxDialogButton(id: Self.name(action), title: PairInviteStrings.button(action, copied: model.copied), role: role)
        // Confirm looks like the default button but no key presses it: only the person's click does.
        let view = action.isPersonClickOnly
            ? CmuxDialogButtonView(spec, hint: nil, target: self, action: #selector(confirmPressed(_:)))
            : CmuxDialogButtonView(standalone: spec, target: self, action: #selector(pressed(_:)))
        view.tag = actions.count
        actions.append(action)
        view.setAccessibilityIdentifier(id)
        return view
    }

    @objc private func pressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        if model.perform(actions[sender.tag]) { onClose() }
    }

    /// SECURITY: a press of Confirm through its action (an Accessibility press, a programmatic click)
    /// confirms nothing: only the person's own click on it does, read by the panel from the click
    /// itself (``PairInviteCardPanel/dispatch(_:_:)``).
    @objc func confirmPressed(_ sender: NSView) {}

    private func waitingRow(_ text: String, width: CGFloat) -> NSView {
        let row = NSStackView()
        row.spacing = Metrics.space2
        row.addArrangedSubview(StatusIndicatorView.spinner())
        row.addArrangedSubview(label(text, font: Typography.body, color: Palette.textSecondary, width: width - 24))
        return row
    }

    private func label(_ text: String, font: NSFont, color: NSColor, width: CGFloat?) -> NSTextField {
        let field = width == nil ? NSTextField(labelWithString: text) : NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        if let width { field.preferredMaxLayoutWidth = width }
        return field
    }
}

/// "Expires in 9:41", redrawn on each countdown tick, in the attention color under a minute.
@MainActor
final class PairInviteCountdownLabel: NSTextField {
    private let model: PairInviteModel

    init(model: PairInviteModel) {
        self.model = model
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = Typography.system(.monospaced, size: TypeScale.caption)
        setAccessibilityIdentifier("cmux.pairInvite.countdown")
        draw()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draws the time left and draws again when it changes. The chain ends with the label: a
    /// change after it left the window finds `self` gone.
    private func draw() {
        withObservationTracking {
            let left = model.secondsLeft ?? 0
            stringValue = PairInviteStrings.expires(left)
            textColor = left < 60 ? Palette.attention : Palette.textSecondary
        } onChange: { [weak self] in
            Task { @MainActor in self?.draw() }
        }
    }
}
