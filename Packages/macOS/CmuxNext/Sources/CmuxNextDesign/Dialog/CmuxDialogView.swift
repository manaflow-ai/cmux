public import AppKit

/// The one cmux dialog view: an overlay panel (Liquid Glass, opaque under
/// Reduce Transparency) with the title, the asking origin, the lines, the
/// fields and the buttons. Keys follow `CmuxDialogKeys`; Tab and Shift-Tab
/// cycle only through the dialog's own controls (the focus trap). A host
/// (`CmuxDialogHosting`) places it; the center (`CmuxDialogCenter`) owns
/// its answer.
@MainActor
public final class CmuxDialogView: NSView {
    public let spec: CmuxDialogSpec
    /// Called once per press with the button id; the center ends the dialog.
    var onPress: ((String) -> Void)?
    private(set) var buttonViews: [CmuxDialogButtonView] = []
    private var inputs: [String: NSControl] = [:]
    /// Text fields, choices, check boxes, then buttons: the focus order.
    private(set) var focusables: [NSView] = []
    private let stack = NSStackView()
    private(set) var surface: OverlaySurfaceView!

    public init(spec: CmuxDialogSpec) {
        self.spec = spec
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilitySubrole(.dialog)
        setAccessibilityLabel(spec.title)
        setAccessibilityHelp(([spec.origin.map(CmuxDialogStrings.from)].compactMap { $0 } + spec.lines).joined(separator: "\n"))
        setAccessibilityModal(true)
        if let identifier = spec.identifier { setAccessibilityIdentifier(identifier) }
        identifier = NSUserInterfaceItemIdentifier(spec.identifier ?? "cmux.dialog")
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

    /// Gives the keyboard to the first text field, else the default button,
    /// else the first control.
    public func focusInitial() {
        let field = focusables.first { $0 is NSTextField }
        let fallback = buttonViews.first { $0.button.role == .default } ?? focusables.first
        guard let target = field ?? fallback else { return }
        window?.makeFirstResponder(target)
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
        let contentWidth = CmuxDialogMetrics.width - padding * 2

        if let data = spec.icon, let image = NSImage(data: data) {
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
            for view in fieldViews(field, width: contentWidth) { stack.addArrangedSubview(view) }
        }
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = Metrics.space2
        row.addArrangedSubview(NSView())
        for button in spec.buttons {
            let view = CmuxDialogButtonView(button, target: self, action: #selector(pressed(_:)))
            buttonViews.append(view)
            row.addArrangedSubview(view)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        focusables += buttonViews
        chainKeyViews()

        let content = NSView()
        content.addSubview(stack)
        let surface = Glass.makeOverlayPanel(content: content)
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

    /// Tab order closes on itself: the last control's next is the first.
    private func chainKeyViews() {
        for (index, view) in focusables.enumerated() {
            view.nextKeyView = focusables[(index + 1) % focusables.count]
        }
    }

    private enum TextRole { case primary, secondary }

    private func label(_ text: String, font: NSFont, role: TextRole, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.preferredMaxLayoutWidth = width
        label.isSelectable = true
        performWithTheme { label.textColor = role == .primary ? Palette.textPrimary : Palette.textSecondary }
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func fieldViews(_ field: CmuxDialogField, width: CGFloat) -> [NSView] {
        switch field {
        case .text(let id, let caption, let initial, let placeholder, let secure):
            let input = secure ? NSSecureTextField(string: initial) : NSTextField(string: initial)
            input.placeholderString = placeholder
            input.font = Typography.body
            input.delegate = self
            input.identifier = NSUserInterfaceItemIdentifier("cmux.dialog.field.\(id)")
            input.setAccessibilityLabel(caption ?? placeholder ?? spec.title)
            input.translatesAutoresizingMaskIntoConstraints = false
            input.widthAnchor.constraint(equalToConstant: width).isActive = true
            input.heightAnchor.constraint(equalToConstant: CmuxDialogMetrics.fieldHeight).isActive = true
            register(input, id: id)
            return captioned(caption, input, width: width)
        case .choice(let id, let caption, let options, let selected):
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            for option in options {
                popup.addItem(withTitle: option.label)
                popup.lastItem?.representedObject = option.value
                if option.value == selected { popup.select(popup.lastItem) }
            }
            popup.identifier = NSUserInterfaceItemIdentifier("cmux.dialog.field.\(id)")
            popup.setAccessibilityLabel(caption ?? spec.title)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: width).isActive = true
            register(popup, id: id)
            return captioned(caption, popup, width: width)
        case .check(let id, let title, let on):
            let check = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            check.state = on ? .on : .off
            check.font = Typography.body
            check.identifier = NSUserInterfaceItemIdentifier("cmux.dialog.field.\(id)")
            register(check, id: id)
            return [check]
        case .preview(let text):
            let preview = label(text, font: .monospacedSystemFont(ofSize: Typography.body.pointSize, weight: .regular),
                                role: .primary, width: width)
            preview.maximumNumberOfLines = 8
            preview.lineBreakMode = .byTruncatingTail
            return [preview]
        }
    }

    private func register(_ control: NSControl, id: String) {
        inputs[id] = control
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
