public import AppKit
public import CmuxNextDesignTokens

/// The one cmux dialog card, drawn by AppKit (dialogs are native chrome: plans/cmux-next/language-layers.md).
/// The icon leads at the left (the spec's, else the app's for a cmux dialog; a web page's dialog, which names
/// its origin, never wears the app's icon), and the title, the asking origin, the lines, the fields and the
/// buttons sit in one column beside it, each button with its key on a keycap (Lawrence 2026-11-09).
///
/// It draws one ``CmuxDialogPresentation``: the person's edits and presses go to it, and the values automation
/// sets and the focus moves keys ask come back through ``CmuxDialogRendering``. Keys follow `CmuxDialogKeys`;
/// Tab and Shift-Tab cycle only through the card's own controls.
@MainActor
public final class CmuxDialogView: NSView, CmuxDialogRendering {
    public let dialog: CmuxDialogPresentation
    public var spec: CmuxDialogSpec { dialog.spec }
    private(set) var buttonViews: [CmuxDialogButtonView] = []
    private var inputs: [String: NSControl] = [:]
    /// Text fields, choices, check boxes, then buttons: the focus order.
    private(set) var focusables: [NSView] = []
    private let body = NSStackView()
    private let row = NSStackView()
    private(set) var surface: CmuxDialogCardSurface?

    public init(dialog: CmuxDialogPresentation) {
        self.dialog = dialog
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        apply(dialog.values)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilitySubrole(.dialog)
        setAccessibilityLabel(spec.title)
        setAccessibilityHelp(([spec.origin.map(CmuxDialogStrings.from)].compactMap { $0 } + spec.lines).joined(separator: "\n"))
        setAccessibilityModal(true)
        identifier = NSUserInterfaceItemIdentifier(spec.identifier ?? "cmux.dialog")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    // MARK: Values

    /// The fields as the person sees them now.
    private var shownValues: [String: CmuxDialogValue] {
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

    /// Shows `values` in the fields (the spec's initial ones, or the ones automation set).
    private func apply(_ values: [String: CmuxDialogValue]) {
        for (id, value) in values {
            switch (inputs[id], value) {
            case (let popup as NSPopUpButton, .text(let text)):
                if let item = popup.itemArray.first(where: { $0.representedObject as? String == text }) { popup.select(item) }
            case (let check as NSButton, .bool(let on)): check.state = on ? .on : .off
            case (let field as NSTextField, .text(let text)): if field.stringValue != text { field.stringValue = text }
            default: break
            }
        }
    }

    /// The person changed a field: the presentation holds what the card shows.
    private func noteEdit() {
        dialog.edited(shownValues)
    }

    @objc private func controlChanged(_ sender: Any?) {
        noteEdit()
    }

    public func dialogValuesChanged(_ dialog: CmuxDialogPresentation) {
        apply(dialog.values)
    }

    public func dialogMoveFocus(_ dialog: CmuxDialogPresentation, backward: Bool) {
        moveFocus(backward: backward)
    }

    // MARK: Keys

    /// Runs `key` against the dialog; true when the dialog used it.
    @discardableResult
    func handle(_ key: CmuxDialogKeys.Key, modifiers: CmuxDialogKeys.Modifiers) -> Bool {
        noteEdit()
        return dialog.handle(key, modifiers: modifiers)
    }

    /// Gives the keyboard to the first text field, else to the card itself: never to a button or check box
    /// the person did not choose, so a key typed on as the dialog opens presses nothing (QA
    /// chrome-parity-v2-1, the paste confirm's Deny). Tab moves onto the first control.
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
        if let key = CmuxDialogPresentation.key(event), handle(key, modifiers: CmuxDialogPresentation.modifiers(event)) { return }
        super.keyDown(with: event)
    }

    /// Command keys and Return reach the dialog before the window's menus while the keyboard is inside it.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard containsKeyboard, let key = CmuxDialogPresentation.key(event) else { return super.performKeyEquivalent(with: event) }
        return handle(key, modifiers: CmuxDialogPresentation.modifiers(event)) || super.performKeyEquivalent(with: event)
    }

    public override func cancelOperation(_ sender: Any?) {
        handle(.escape, modifiers: [])
    }

    var containsKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    @objc private func pressed(_ sender: CmuxDialogButtonView) {
        noteEdit()
        dialog.press(sender.button.id)
    }

    // MARK: Layout

    /// The icon the card leads with: the spec's, else the app's for a cmux dialog; none for a web page's.
    static func icon(for spec: CmuxDialogSpec) -> NSImage? {
        if let data = spec.icon { return NSImage(data: data) }
        guard spec.origin == nil else { return nil }
        return NSApplication.shared.applicationIconImage
    }

    private func build() {
        let icon = Self.icon(for: spec)
        let padding = CmuxDialogMetrics.cardPadding
        let cardWidth = icon == nil ? CmuxDialogMetrics.width : CmuxDialogMetrics.widthWithIcon
        let contentWidth = cardWidth - padding * 2 - (icon == nil ? 0 : CmuxDialogMetrics.iconSize + CmuxDialogMetrics.iconGap)

        let outer = NSStackView()
        outer.orientation = .horizontal
        outer.alignment = .top
        outer.spacing = CmuxDialogMetrics.iconGap
        outer.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        outer.translatesAutoresizingMaskIntoConstraints = false
        if let icon {
            let view = NSImageView(image: icon)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false)
            view.widthAnchor.constraint(equalToConstant: CmuxDialogMetrics.iconSize).isActive = true
            view.heightAnchor.constraint(equalToConstant: CmuxDialogMetrics.iconSize).isActive = true
            outer.addArrangedSubview(view)
        }
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = CmuxDialogMetrics.spacing
        body.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(body)
        body.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let titleFont = Typography.system(.default, size: TypeScale.title, weight: TypeScale.emphasis)
        let title = label(spec.title, font: titleFont, role: .primary, width: contentWidth)
        body.addArrangedSubview(title)
        if let origin = spec.origin {
            body.addArrangedSubview(label(CmuxDialogStrings.from(origin), font: Typography.caption, role: .secondary, width: contentWidth))
        }
        if !spec.lines.isEmpty {
            let lines = linesView(width: contentWidth)
            // The first line reads as the title's subtitle, close under it.
            if spec.origin == nil { body.setCustomSpacing(CmuxDialogMetrics.subtitleGap, after: title) }
            body.addArrangedSubview(lines)
        }
        // A safe-default dialog puts its check boxes under the buttons, as NSAlert puts its suppression button.
        let safeDefault = spec.layout == .safeDefault
        let trailing = safeDefault ? spec.fields.filter { if case .check = $0 { true } else { false } } : []
        for field in spec.fields where !trailing.contains(field) {
            for view in fieldViews(field, width: contentWidth) { body.addArrangedSubview(view) }
        }
        for button in spec.buttons {
            buttonViews.append(CmuxDialogButtonView(button, hint: dialog.hint(for: button), quiet: safeDefault && button.role == .destructive,
                                                    keycap: true, target: self, action: #selector(pressed(_:))))
        }
        let main = buttonViews.filter { !$0.isQuiet }
        Self.fillButtonRow(row, main, width: contentWidth)
        body.setCustomSpacing(CmuxDialogMetrics.buttonsGap, after: body.arrangedSubviews.last ?? title)
        body.addArrangedSubview(row)
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        // Tab follows what the person sees: left to right on one line, top to bottom when stacked.
        focusables += row.orientation == .vertical ? main.reversed() : main
        let quiet = buttonViews.filter(\.isQuiet)
        if !quiet.isEmpty {
            let quietRow = Self.quietRow(quiet, width: contentWidth)
            body.setCustomSpacing(Metrics.space2, after: row)
            body.addArrangedSubview(quietRow)
            focusables += quiet
        }
        for field in trailing {
            for view in fieldViews(field, width: contentWidth) { body.addArrangedSubview(view) }
        }
        chainKeyViews()
        // A horizontal stack aligned to the top keeps its top inset but not its bottom one: hold each arranged
        // view above it, or the buttons sit on the card's bottom edge.
        for view in outer.arrangedSubviews {
            view.bottomAnchor.constraint(lessThanOrEqualTo: outer.bottomAnchor, constant: -padding).isActive = true
        }

        let content = NSView()
        content.addSubview(outer)
        // The card keeps the key-window glass while it fades out (debug.dialog_strip).
        let surface = CmuxDialogCardSurface(content: content, activeLook: dialog.activeLook)
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        self.surface = surface
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: cardWidth),
            heightAnchor.constraint(equalTo: outer.heightAnchor),
        ])
    }

    /// The lines; a long message (an import preview) scrolls in a box of bounded height, so the buttons stay on screen.
    private func linesView(width: CGFloat) -> NSView {
        let lines = NSStackView(views: spec.lines.map { label($0, font: Typography.body, role: .secondary, width: width) })
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = Metrics.space2
        lines.translatesAutoresizingMaskIntoConstraints = false
        guard spec.lines.count > CmuxDialogMetrics.scrollingLineCount
            || spec.lines.reduce(0, { $0 + $1.count }) > CmuxDialogMetrics.scrollingCharacterCount else { return lines }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = lines
        let clip = scroll.contentView
        let fit = scroll.heightAnchor.constraint(equalTo: lines.heightAnchor)
        fit.priority = .defaultHigh
        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            lines.topAnchor.constraint(equalTo: clip.topAnchor),
            lines.widthAnchor.constraint(equalToConstant: width),
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: Self.cutHeight(Typography.body, spacing: lines.spacing)),
            fit,
        ])
        return scroll
    }

    /// The scrolling box's height: at most ``CmuxDialogMetrics/linesMaxHeight``, ending halfway through a line, so the
    /// person sees the message goes on (a box that ends on a line's edge reads as the whole list, with no scroller
    /// shown until they scroll).
    private static func cutHeight(_ font: NSFont, spacing: CGFloat) -> CGFloat {
        let line = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let pitch = line + spacing
        let whole = max(floor((CmuxDialogMetrics.linesMaxHeight - line / 2) / pitch), 1)
        return whole * pitch + line / 2
    }

    /// The buttons on one line, right-aligned, when they fit in `width`; else stacked, each `width` wide and the
    /// default on top, as NSAlert stacks buttons that do not fit (a long locale).
    private static func fillButtonRow(_ row: NSStackView, _ buttons: [CmuxDialogButtonView], width: CGFloat) {
        row.translatesAutoresizingMaskIntoConstraints = false
        row.spacing = Metrics.space2
        let needed = buttons.reduce(0) { $0 + $1.intrinsicContentSize.width }
            + row.spacing * CGFloat(max(buttons.count - 1, 0))
        guard needed > width else {
            row.orientation = .horizontal
            row.addArrangedSubview(NSView())
            for button in buttons { row.addArrangedSubview(button) }
            return
        }
        row.orientation = .vertical
        row.alignment = .leading
        // The spec draws the primary button last (rightmost); stacked, it goes first (top).
        for button in buttons.reversed() {
            row.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
    }

    /// A safe-default dialog's destructive choices: quiet text buttons, leading, on one line when they fit in
    /// `width`, else one under another; never the card's width (they are not the answer to reach for).
    private static func quietRow(_ buttons: [CmuxDialogButtonView], width: CGFloat) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.spacing = Metrics.space2
        let needed = buttons.reduce(0) { $0 + $1.intrinsicContentSize.width } + row.spacing * CGFloat(max(buttons.count - 1, 0))
        row.orientation = needed > width ? .vertical : .horizontal
        row.alignment = row.orientation == .vertical ? .leading : .centerY
        return row
    }

    /// Tab order closes on itself: the last control's next is the first.
    private func chainKeyViews() {
        for (index, view) in focusables.enumerated() {
            view.nextKeyView = focusables[(index + 1) % focusables.count]
        }
    }

    private enum TextRole { case primary, secondary }

    /// A themed label: it re-reads its ink in the scope it draws in (on joining a window and on every theme
    /// change), never the scope it was built in.
    private func label(_ text: String, font: NSFont, role: TextRole, width: CGFloat) -> ThemedLabel {
        let label = ThemedLabel(wrappingLabelWithString: text)
        label.font = font
        label.preferredMaxLayoutWidth = width
        label.isSelectable = true
        label.focusRingType = .none
        // Fitted to the dialog's glass card, as its buttons are (GlassTextEveryThemeTests).
        label.themeColor = role == .primary ? { Palette.sheetText(.primary) } : { Palette.sheetText(.secondary) }
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func fieldViews(_ field: CmuxDialogField, width: CGFloat) -> [NSView] {
        switch field {
        case .text(let id, let caption, let initial, let placeholder, let secure):
            let input: NSTextField = secure ? ThemedSecureTextField(string: initial) : ThemedTextField(string: initial)
            input.font = Typography.body
            input.placeholderString = placeholder
            input.delegate = self
            input.identifier = NSUserInterfaceItemIdentifier("cmux.dialog.field.\(id)")
            input.setAccessibilityLabel(caption ?? placeholder ?? spec.title)
            register(input, id: id)
            let box = ThemedFieldBox(field: input, height: CmuxDialogMetrics.fieldHeight)
            box.widthAnchor.constraint(equalToConstant: width).isActive = true
            return captioned(caption, box, width: width)
        case .choice(let id, let caption, let options, _):
            let popup = ThemedPopUpButton(frame: .zero, pullsDown: false)
            // A disabled option lists greyed out and is never the selection.
            popup.autoenablesItems = false
            for option in options {
                popup.addItem(withTitle: option.label)
                popup.lastItem?.representedObject = option.value
                popup.lastItem?.isEnabled = option.isEnabled
            }
            popup.target = self
            popup.action = #selector(controlChanged(_:))
            popup.identifier = NSUserInterfaceItemIdentifier("cmux.dialog.field.\(id)")
            popup.setAccessibilityLabel(caption ?? spec.title)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: width).isActive = true
            register(popup, id: id)
            return captioned(caption, popup, width: width)
        case .check(let id, let title, _):
            let check = ThemedCheckbox(checkboxWithTitle: title, target: self, action: #selector(controlChanged(_:)))
            check.font = Typography.body
            check.identifier = NSUserInterfaceItemIdentifier("cmux.dialog.field.\(id)")
            register(check, id: id)
            return [check]
        case .preview(let text):
            let preview = label(text, font: Typography.system(.monospaced, size: TypeScale.body), role: .primary, width: width)
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
    public func controlTextDidChange(_ notification: Notification) {
        noteEdit()
    }

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
