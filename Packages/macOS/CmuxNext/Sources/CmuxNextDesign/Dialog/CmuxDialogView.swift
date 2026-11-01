public import AppKit
import CmuxNextCompat
public import CmuxNextDesignTokens

/// The one cmux dialog view: an overlay panel (Liquid Glass, opaque under
/// Reduce Transparency) with the title, the asking origin, the lines, the
/// fields and the buttons. Keys follow `CmuxDialogKeys`; Tab and Shift-Tab
/// cycle only through the dialog's own controls (the focus trap). A host
/// (`CmuxDialogHosting`) places it; the center (`CmuxDialogCenter`) owns
/// its answer.
@MainActor
public final class CmuxDialogView: NSView {
    public private(set) var spec: CmuxDialogSpec
    /// Called once per press with the button id; the center ends the dialog.
    var onPress: ((String) -> Void)?
    private(set) var buttonViews: [CmuxDialogButtonView] = []
    private var inputs: [String: NSControl] = [:]
    /// Each input's row in the stack (the control, or the box around a text field).
    private var inputRows: [String: NSView] = [:]
    /// Text fields, choices, check boxes, then buttons: the focus order.
    private(set) var focusables: [NSView] = []
    private let stack = NSStackView()
    private(set) var surface: OverlaySurfaceView?

    public init(spec: CmuxDialogSpec) {
        self.spec = spec
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilitySubrole(.dialog)
        setAccessibilityModal(true)
        describe()
    }

    private func describe() {
        setAccessibilityLabel(spec.title)
        setAccessibilityHelp(([spec.origin.map(CmuxDialogStrings.from)].compactMap { $0 } + spec.lines).joined(separator: "\n"))
        if let identifier = spec.identifier { setAccessibilityIdentifier(identifier) }
        identifier = NSUserInterfaceItemIdentifier(spec.identifier ?? "cmux.dialog")
    }

    /// Shows `spec` in this panel in place of the current one (a chooser's rows changed), as Chrome's
    /// device chooser updates its table in its open bubble (chrome/browser/ui/views/device_chooser_content_view.cc):
    /// the panel stays, a field with the same id keeps its control (an open pop-up menu stays open), and
    /// the keyboard stays on the control with the same id. The fields show `spec`'s values.
    public func update(_ spec: CmuxDialogSpec) {
        guard spec != self.spec else { return }
        let hadKeyboard = containsKeyboard
        let focused = focusedIndex.flatMap { focusKey(focusables[$0]) }
        let reusable = inputs
        let reusableRows = inputRows
        let old = stack.arrangedSubviews
        // Out of the stack's order but still in the window, so a kept control keeps the keyboard.
        for view in old { stack.removeArrangedSubview(view) }
        self.spec = spec
        buttonViews = []
        inputs = [:]
        inputRows = [:]
        focusables = []
        buildContents(reusing: reusable, rows: reusableRows)
        let kept = Set(stack.arrangedSubviews.map { ObjectIdentifier($0) })
        for view in old where !kept.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        describe()
        guard hadKeyboard else { return }
        if let focused, let target = focusables.first(where: { focusKey($0) == focused }) {
            // A kept text field's editor keeps its caret and selection.
            let responder = window?.firstResponder as? NSView
            if responder.map({ $0 === target || $0.isDescendant(of: target) }) != true { window?.makeFirstResponder(target) }
        } else {
            focusInitial()
        }
    }

    /// A focusable control's stable name: its field's id or its button's id.
    private func focusKey(_ view: NSView) -> String? {
        if let button = view as? CmuxDialogButtonView { return "button.\(button.button.id)" }
        return inputs.first { $0.value === view }.map { "field.\($0.key)" }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Values

    /// Every field's current value by field id.
    public var values: [String: CmuxDialogValue] {
        var values: [String: CmuxDialogValue] = [:]
        for (id, control) in inputs {
            switch control {
            case let popup as NSPopUpButton: values[id] = .text(popup.selectedItem?.representedObject as? String ?? "")
            case let check as NSButton: values[id] = .bool(check.state == .on)
            case let field as NSTextField: values[id] = .text(field.stringValue)
            default: break
            }
        }
        return values
    }

    /// Sets one field (automation); false when the dialog has no such field
    /// or the value does not fit it.
    @discardableResult
    public func setValue(_ value: CmuxDialogValue, for id: String) -> Bool {
        switch (inputs[id], value) {
        case (let popup as NSPopUpButton, .text(let text)):
            guard let item = popup.itemArray.first(where: { $0.representedObject as? String == text }) else { return false }
            popup.select(item)
        case (let check as NSButton, .bool(let on)): check.state = on ? .on : .off
        case (let field as NSTextField, .text(let text)): field.stringValue = text
        default: return false
        }
        return true
    }

    // MARK: Keys

    /// Runs `key` against this dialog; true when the dialog used it.
    @discardableResult
    public func handle(_ key: CmuxDialogKeys.Key, modifiers: CmuxDialogKeys.Modifiers) -> Bool {
        guard let action = CmuxDialogKeys.action(for: key, modifiers: modifiers, in: spec) else { return false }
        switch action {
        case .press(let id): press(id)
        case .focusNext: moveFocus(backward: false)
        case .focusPrevious: moveFocus(backward: true)
        }
        return true
    }

    /// Gives the keyboard to the first text field, else to the dialog itself:
    /// never to a button or check box the person did not choose, so a key typed
    /// on as the dialog opens presses nothing (a Space pressed the focused
    /// button: QA chrome-parity-v2-1, the paste confirm's Deny). The dialog
    /// answers Return, Escape and Command keys (`CmuxDialogKeys`); Tab moves
    /// onto the first control, where Space then presses what the person chose.
    public func focusInitial() {
        window?.makeFirstResponder(focusables.first { $0 is NSTextField } ?? self)
    }

    /// The index in `focusables` of the control with the keyboard.
    var focusedIndex: Int? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        return focusables.firstIndex { responder === $0 || responder.isDescendant(of: $0) }
    }

    private func moveFocus(backward: Bool) {
        guard let next = CmuxDialogKeys.focus(after: focusedIndex, count: focusables.count, backward: backward) else { return }
        window?.makeFirstResponder(focusables[next])
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        if let key = Self.key(event), handle(key, modifiers: Self.modifiers(event)) { return }
        super.keyDown(with: event)
    }

    /// Command keys and Return reach the dialog before the window's menus
    /// while the keyboard is inside it.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard containsKeyboard, let key = Self.key(event) else { return super.performKeyEquivalent(with: event) }
        return handle(key, modifiers: Self.modifiers(event)) || super.performKeyEquivalent(with: event)
    }

    public override func cancelOperation(_ sender: Any?) {
        handle(.escape, modifiers: [])
    }

    var containsKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    static func key(_ event: NSEvent) -> CmuxDialogKeys.Key? {
        switch event.keyCode {
        case 36, 76: return .return
        case 53: return .escape
        case 48: return .tab
        default: return event.charactersIgnoringModifiers?.first.map { .character($0) }
        }
    }

    static func modifiers(_ event: NSEvent) -> CmuxDialogKeys.Modifiers {
        var modifiers: CmuxDialogKeys.Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    // MARK: Presses

    /// Presses the button `id`; false when the dialog has no such button.
    @discardableResult
    public func press(_ id: String) -> Bool {
        guard spec.buttons.contains(where: { $0.id == id }) else { return false }
        onPress?(id)
        return true
    }

    @objc private func pressed(_ sender: CmuxDialogButtonView) {
        press(sender.button.id)
    }

    // MARK: Layout

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CmuxDialogMetrics.spacing
        let padding = CmuxDialogMetrics.padding
        stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buildContents(reusing: [:], rows: [:])
        layoutSurface(NSView())
    }

    /// The stack's rows for `spec`; a field whose id is in `reusable` keeps that control (and its row).
    private func buildContents(reusing reusable: [String: NSControl], rows: [String: NSView]) {
        let contentWidth = CmuxDialogMetrics.width - CmuxDialogMetrics.padding * 2
        if let data = spec.icon, let image = blockingNSImage(data) {
            let icon = NSImageView(image: image)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: CmuxDialogMetrics.iconSize).isActive = true
            icon.heightAnchor.constraint(equalToConstant: CmuxDialogMetrics.iconSize).isActive = true
            stack.addArrangedSubview(icon)
        }
        stack.addArrangedSubview(label(spec.title, font: Typography.bodyEmphasized, role: .primary, width: contentWidth))
        if let origin = spec.origin {
            stack.addArrangedSubview(label(CmuxDialogStrings.from(origin), font: Typography.caption, role: .secondary, width: contentWidth))
        }
        for line in spec.lines {
            stack.addArrangedSubview(label(line, font: Typography.body, role: .secondary, width: contentWidth))
        }
        for field in spec.fields {
            for view in fieldViews(field, width: contentWidth, reusing: reusable, rows: rows) { stack.addArrangedSubview(view) }
        }
        for button in spec.buttons {
            buttonViews.append(CmuxDialogButtonView(button, hint: CmuxDialogKeys.hint(for: button, in: spec), target: self,
                                                    action: #selector(pressed(_:))))
        }
        let row = Self.buttonRow(buttonViews, width: contentWidth)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        // Tab follows what the person sees: left to right on one line, top to bottom when stacked.
        focusables += row.orientation == .vertical ? buttonViews.reversed() : buttonViews
        chainKeyViews()
    }

    private func layoutSurface(_ content: NSView) {
        content.addSubview(stack)
        let surface = Glass.makeOverlayPanel(content: content, tone: .neutralGlass(.dialog))
        addSubview(surface)
        self.surface = surface
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: CmuxDialogMetrics.width),
            heightAnchor.constraint(equalTo: stack.heightAnchor),
        ])
    }

    /// The buttons on one line, right-aligned, when they fit in `width`; else stacked, each `width` wide and the
    /// default on top, as NSAlert stacks buttons that do not fit (the quit choice's four buttons, a long locale).
    private static func buttonRow(_ buttons: [CmuxDialogButtonView], width: CGFloat) -> NSStackView {
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.spacing = Metrics.space2
        let needed = buttons.reduce(0) { $0 + $1.intrinsicContentSize.width }
            + row.spacing * CGFloat(max(buttons.count - 1, 0))
        guard needed > width else {
            row.orientation = .horizontal
            row.addArrangedSubview(NSView())
            for button in buttons { row.addArrangedSubview(button) }
            return row
        }
        row.orientation = .vertical
        row.alignment = .leading
        // The spec draws the primary button last (rightmost); stacked, it goes first (top).
        for button in buttons.reversed() {
            row.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return row
    }

    /// Tab order closes on itself: the last control's next is the first.
    private func chainKeyViews() {
        for (index, view) in focusables.enumerated() {
            view.nextKeyView = focusables[(index + 1) % focusables.count]
        }
    }

    private enum TextRole { case primary, secondary }

    /// A themed label: it re-reads its ink in the scope it draws in (on joining
    /// a window and on every theme change), never the scope it was built in.
    private func label(_ text: String, font: NSFont, role: TextRole, width: CGFloat) -> ThemedLabel {
        let label = ThemedLabel(wrappingLabelWithString: text)
        label.font = font
        label.preferredMaxLayoutWidth = width
        label.isSelectable = true
        label.focusRingType = .none
        label.ink = role == .primary ? .primary : .secondary
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func fieldViews(_ field: CmuxDialogField, width: CGFloat, reusing reusable: [String: NSControl],
                            rows: [String: NSView]) -> [NSView] {
        switch field {
        case .text(let id, let caption, let initial, let placeholder, let secure):
            let row: NSView
            let input: NSTextField
            if let kept = reusable[id] as? NSTextField, (kept is NSSecureTextField) == secure, let keptRow = rows[id] {
                input = kept
                row = keptRow
                // The same text keeps the caret where it is.
                if input.stringValue != initial { input.stringValue = initial }
            } else {
                input = secure ? ThemedSecureTextField(string: initial) : ThemedTextField(string: initial)
                input.font = Typography.body
                input.delegate = self
                input.identifier = NSUserInterfaceItemIdentifier("cmux.dialog.field.\(id)")
                let box = ThemedFieldBox(field: input, height: CmuxDialogMetrics.fieldHeight)
                box.widthAnchor.constraint(equalToConstant: width).isActive = true
                row = box
            }
            input.placeholderString = placeholder
            input.setAccessibilityLabel(caption ?? placeholder ?? spec.title)
            register(input, id: id, row: row)
            return captioned(caption, row, width: width)
        case .choice(let id, let caption, let options, let selected):
            let popup: NSPopUpButton
            if let kept = reusable[id] as? ThemedPopUpButton {
                popup = kept
                popup.removeAllItems()
            } else {
                popup = ThemedPopUpButton(frame: .zero, pullsDown: false)
                // A disabled option lists greyed out and is never the selection.
                popup.autoenablesItems = false
                popup.identifier = NSUserInterfaceItemIdentifier("cmux.dialog.field.\(id)")
                popup.translatesAutoresizingMaskIntoConstraints = false
                popup.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
            for option in options {
                popup.addItem(withTitle: option.label)
                popup.lastItem?.representedObject = option.value
                popup.lastItem?.isEnabled = option.isEnabled
                if option.value == selected, option.isEnabled { popup.select(popup.lastItem) }
            }
            if popup.selectedItem?.isEnabled != true, let first = popup.itemArray.first(where: \.isEnabled) { popup.select(first) }
            popup.setAccessibilityLabel(caption ?? spec.title)
            register(popup, id: id, row: popup)
            return captioned(caption, popup, width: width)
        case .check(let id, let title, let on):
            let check: NSButton
            if let kept = reusable[id] as? ThemedCheckbox {
                check = kept
                check.title = title
            } else {
                check = ThemedCheckbox(checkboxWithTitle: title, target: nil, action: nil)
                check.font = Typography.body
                check.identifier = NSUserInterfaceItemIdentifier("cmux.dialog.field.\(id)")
            }
            check.state = on ? .on : .off
            register(check, id: id, row: check)
            return [check]
        case .preview(let text):
            let preview = label(text, font: .monospacedSystemFont(ofSize: Typography.body.pointSize, weight: .regular),
                                role: .primary, width: width)
            preview.maximumNumberOfLines = 8
            preview.lineBreakMode = .byTruncatingTail
            return [preview]
        }
    }

    private func register(_ control: NSControl, id: String, row: NSView) {
        inputs[id] = control
        inputRows[id] = row
        focusables.append(control)
    }

    private func captioned(_ caption: String?, _ view: NSView, width: CGFloat) -> [NSView] {
        guard let caption else { return [view] }
        return [label(caption, font: Typography.caption, role: .secondary, width: width), view]
    }
}

extension CmuxDialogView: NSTextFieldDelegate {
    /// Return, Escape and Tab inside a text field follow the dialog keys.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): handle(.return, modifiers: [])
        case #selector(NSResponder.cancelOperation(_:)): handle(.escape, modifiers: [])
        case #selector(NSResponder.insertTab(_:)): handle(.tab, modifiers: [])
        case #selector(NSResponder.insertBacktab(_:)): handle(.tab, modifiers: .shift)
        default: false
        }
    }
}
