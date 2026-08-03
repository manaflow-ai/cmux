import AppKit

@MainActor
final class MarkdownTypographyButtonView: NSButton, NSPopoverDelegate {
    private weak var panel: MarkdownPanel?
    private var popover: NSPopover?
    private var contentController: MarkdownTypographyPopoverViewController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(
            systemSymbolName: "textformat.size",
            accessibilityDescription: String(localized: "markdown.toolbar.fontSize", defaultValue: "Font Size")
        )
        imageScaling = .scaleProportionallyDown
        target = self
        action = #selector(togglePopover(_:))
        toolTip = String(localized: "markdown.toolbar.fontSize", defaultValue: "Font Size")
        setAccessibilityLabel(toolTip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(panel: MarkdownPanel) {
        self.panel = panel
        contentController?.update(panel: panel)
    }

    func teardown() {
        popover?.close()
        contentController?.teardown()
        contentController = nil
        popover = nil
        panel = nil
    }

    @objc private func togglePopover(_ sender: NSButton) {
        if popover?.isShown == true {
            popover?.performClose(sender)
            return
        }
        guard let panel else { return }
        let controller = MarkdownTypographyPopoverViewController(panel: panel)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 272, height: controller.preferredHeight)
        popover.delegate = self
        self.contentController = controller
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        contentController?.teardown()
        contentController = nil
        popover = nil
    }
}

@MainActor
private final class MarkdownTypographyPopoverViewController: NSViewController,
    NSTextFieldDelegate
{
    private static let labelColumnWidth: CGFloat = 66
    private weak var panel: MarkdownPanel?
    private let fontPicker = NSPopUpButton()
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let maxWidthField = NSTextField()
    private let maxWidthStepper = NSStepper()
    private var fontLoadTask: Task<Void, Never>?
    private var families: [String] = []
    private var isSynchronizing = false
    let preferredHeight: CGFloat = 244

    init(panel: MarkdownPanel) {
        self.panel = panel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 12
        controls.addArrangedSubview(makeFontRow())
        controls.addArrangedSubview(makeNumberRow(
            label: String(localized: "markdown.typography.size", defaultValue: "Size"),
            field: sizeField,
            unit: String(localized: "markdown.fontSize.unit", defaultValue: "pt"),
            stepper: sizeStepper
        ))
        controls.addArrangedSubview(makeNumberRow(
            label: String(localized: "markdown.typography.maxWidth", defaultValue: "Max Width"),
            field: maxWidthField,
            unit: String(localized: "markdown.maxWidth.unit", defaultValue: "px"),
            stepper: maxWidthStepper
        ))

        let separator = NSBox()
        separator.boxType = .separator

        let actions = NSStackView()
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 8
        actions.addArrangedSubview(actionButton(
            String(localized: "markdown.fontSize.reset", defaultValue: "Reset to default"),
            action: #selector(resetToDefault(_:))
        ))
        actions.addArrangedSubview(actionButton(
            String(localized: "markdown.typography.resetBuiltIn", defaultValue: "Reset to built-in defaults"),
            action: #selector(resetBuiltIn(_:))
        ))
        actions.addArrangedSubview(actionButton(
            String(localized: "markdown.fontSize.setDefault", defaultValue: "Set as default for new viewers"),
            action: #selector(setAsDefault(_:))
        ))

        let stack = NSStackView(views: [controls, separator, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -14),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
        configureControls()
        synchronizeFromPanel()
        loadFontFamilies()
    }

    func update(panel: MarkdownPanel) {
        self.panel = panel
        guard isViewLoaded else { return }
        synchronizeFromPanel()
    }

    func teardown() {
        fontLoadTask?.cancel()
        fontLoadTask = nil
        panel = nil
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isSynchronizing else { return }
        if notification.object as? NSTextField === sizeField {
            applySizeTextIfValid()
        } else if notification.object as? NSTextField === maxWidthField {
            applyMaxWidthTextIfValid()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        synchronizeFromPanel()
    }

    private func configureControls() {
        fontPicker.target = self
        fontPicker.action = #selector(fontChanged(_:))

        sizeField.alignment = .right
        sizeField.delegate = self
        sizeField.placeholderString = String(localized: "markdown.fontSize.field", defaultValue: "Size")
        sizeStepper.minValue = MarkdownFontSizeSettings.minimumPointSize
        sizeStepper.maxValue = MarkdownFontSizeSettings.maximumPointSize
        sizeStepper.increment = MarkdownFontSizeSettings.stepPointSize
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeStepped(_:))

        maxWidthField.alignment = .right
        maxWidthField.delegate = self
        maxWidthField.placeholderString = String(localized: "markdown.maxWidth.field", defaultValue: "Width")
        maxWidthStepper.minValue = MarkdownMaxWidthSettings.minimumCSSPixels
        maxWidthStepper.maxValue = MarkdownMaxWidthSettings.maximumCSSPixels
        maxWidthStepper.increment = MarkdownMaxWidthSettings.stepCSSPixels
        maxWidthStepper.target = self
        maxWidthStepper.action = #selector(maxWidthStepped(_:))
    }

    private func makeFontRow() -> NSView {
        fontPicker.widthAnchor.constraint(equalToConstant: 150).isActive = true
        return row(
            label: String(localized: "markdown.typography.font", defaultValue: "Font"),
            control: fontPicker
        )
    }

    private func makeNumberRow(
        label: String,
        field: NSTextField,
        unit: String,
        stepper: NSStepper
    ) -> NSView {
        field.widthAnchor.constraint(equalToConstant: label == String(localized: "markdown.typography.size", defaultValue: "Size") ? 44 : 54).isActive = true
        let unitLabel = NSTextField(labelWithString: unit)
        unitLabel.textColor = .secondaryLabelColor
        let controls = NSStackView(views: [field, unitLabel, stepper])
        controls.orientation = .horizontal
        controls.alignment = .firstBaseline
        controls.spacing = 6
        return row(label: label, control: controls)
    }

    private func row(label title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 14
        return row
    }

    private func actionButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .linkColor
        return button
    }

    private func loadFontFamilies() {
        guard families.isEmpty, fontLoadTask == nil else { return }
        fontLoadTask = Task { @MainActor [weak self] in
            let families = await MarkdownFontFamily.availableFamilies()
            guard !Task.isCancelled, let self else { return }
            self.families = families
            self.rebuildFontPicker()
        }
    }

    private func rebuildFontPicker() {
        guard let panel else { return }
        let current = panel.fontFamily
        var choices = families
        if !current.isEmpty, !choices.contains(current) {
            choices.insert(current, at: 0)
        }
        fontPicker.removeAllItems()
        fontPicker.addItem(withTitle: String(localized: "markdown.font.system", defaultValue: "System"))
        fontPicker.menu?.addItem(.separator())
        for family in choices {
            fontPicker.addItem(withTitle: family)
        }
        if current.isEmpty {
            fontPicker.selectItem(at: 0)
        } else {
            fontPicker.selectItem(withTitle: current)
        }
    }

    private func synchronizeFromPanel() {
        guard let panel else { return }
        isSynchronizing = true
        sizeField.stringValue = String(Int(panel.fontSize.rounded()))
        sizeStepper.doubleValue = panel.fontSize
        maxWidthField.stringValue = String(Int(panel.maxContentWidth.rounded()))
        maxWidthStepper.doubleValue = panel.maxContentWidth
        rebuildFontPicker()
        isSynchronizing = false
    }

    private func applySizeTextIfValid() {
        guard let panel,
              let value = Double(sizeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value >= MarkdownFontSizeSettings.minimumPointSize,
              value <= MarkdownFontSizeSettings.maximumPointSize else { return }
        _ = panel.setFontSize(value)
        sizeStepper.doubleValue = panel.fontSize
    }

    private func applyMaxWidthTextIfValid() {
        guard let panel,
              let value = Double(maxWidthField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value >= MarkdownMaxWidthSettings.minimumCSSPixels,
              value <= MarkdownMaxWidthSettings.maximumCSSPixels else { return }
        _ = panel.setMaxContentWidth(value)
        maxWidthStepper.doubleValue = panel.maxContentWidth
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        guard let panel else { return }
        let selected = sender.indexOfSelectedItem == 0
            ? MarkdownFontFamily.systemDefault
            : sender.titleOfSelectedItem ?? MarkdownFontFamily.systemDefault
        _ = panel.setFontFamily(selected)
    }

    @objc private func sizeStepped(_ sender: NSStepper) {
        guard let panel else { return }
        _ = panel.setFontSize(sender.doubleValue)
        synchronizeFromPanel()
    }

    @objc private func maxWidthStepped(_ sender: NSStepper) {
        guard let panel else { return }
        _ = panel.setMaxContentWidth(sender.doubleValue)
        synchronizeFromPanel()
    }

    @objc private func resetToDefault(_ sender: NSButton) {
        panel?.resetTypography()
        synchronizeFromPanel()
    }

    @objc private func resetBuiltIn(_ sender: NSButton) {
        panel?.resetTypographyToBuiltInDefaults()
        synchronizeFromPanel()
    }

    @objc private func setAsDefault(_ sender: NSButton) {
        guard let panel else { return }
        MarkdownTypographyDefaults.setDefault(
            fontSize: panel.fontSize,
            fontFamily: panel.fontFamily,
            maxContentWidth: panel.maxContentWidth
        )
    }

    isolated deinit {
        fontLoadTask?.cancel()
    }
}
