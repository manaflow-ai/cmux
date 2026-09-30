import AppKit
import CmuxNextDesign
import QuartzCore

/// Owns the group editor bubble. Every item emits one `TabGroupCommand`
/// (an action id for the App's registry); the editor never edits state.
final class TabGroupEditorController {
    var onCommand: ((TabGroupCommand) -> Void)?
    private var panel: TabGroupEditorPanel?
    private(set) var shownGroupID: TabGroupID?

    var isVisible: Bool { shownGroupID != nil }

    func show(group: TabGroupItem, anchor: CGRect, parent: NSWindow) {
        let panel = panel ?? TabGroupEditorPanel()
        self.panel = panel
        panel.onCommand = { [weak self] command in self?.onCommand?(command) }
        panel.onClose = { [weak self] in self?.shownGroupID = nil }
        shownGroupID = group.id
        panel.configure(group)
        panel.present(below: anchor, parent: parent)
    }

    /// Refreshes the visible editor (color or saved state changed elsewhere).
    func update(group: TabGroupItem) {
        guard shownGroupID == group.id else { return }
        panel?.configure(group)
    }

    func hide() {
        guard shownGroupID != nil else { return }
        panel?.dismiss()
    }
}

/// Liquid Glass bubble: name field, color swatches, and group actions.
final class TabGroupEditorPanel: ActiveAppKeyPanel, NSTextFieldDelegate {
    var onCommand: ((TabGroupCommand) -> Void)?
    var onClose: (() -> Void)?

    private let nameField = NSTextField()
    private var swatches: [TabGroupSwatchView] = []
    private var saveRow: TabGroupEditorRow?
    private var group: TabGroupItem?
    private var dismissing = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        ThemeStore.shared.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let content = NSView()
        let glass = Glass.makePanel(content: content, cornerRadius: Metrics.panelCornerRadius)
        glass.translatesAutoresizingMaskIntoConstraints = true
        contentView = glass
        build(in: content)
        setAccessibilityLabel(Strings.axGroupEditor)
        // Shown without the keys (app inactive): close once another window takes them.
        onKeyElsewhere = { [weak self] in self?.dismiss() }
    }

    override var canBecomeMain: Bool { false }

    private func build(in content: NSView) {
        nameField.placeholderString = Strings.editorNamePlaceholder
        nameField.font = Typography.body
        nameField.textColor = Palette.textPrimary
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.delegate = self
        nameField.lineBreakMode = .byTruncatingTail
        let field = NSView()
        field.wantsLayer = true
        field.layer?.cornerRadius = Metrics.itemCornerRadius
        field.layer?.cornerCurve = .continuous
        field.layer?.backgroundColor = Palette.hoverFill.cgColor
        nameField.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(nameField)

        swatches = GroupColor.allCases.map { color in
            let swatch = TabGroupSwatchView(color: color)
            swatch.onPick = { [weak self] picked in self?.pick(picked) }
            return swatch
        }
        let swatchRow = NSStackView(views: swatches)
        swatchRow.spacing = Metrics.space2
        swatchRow.distribution = .equalSpacing

        let separator = NSBox()
        separator.boxType = .separator

        let save = row(Strings.editorSave) { [weak self] group in group.isSaved ? .unsave(group.id) : .save(group.id) }
        saveRow = save
        let rows = [
            row(Strings.editorNewTab) { .newTab($0.id) },
            row(Strings.editorUngroup) { .ungroup($0.id) },
            row(Strings.editorClose) { .close($0.id) },
            row(Strings.editorMoveToNewWindow) { .moveToNewWindow($0.id) },
            save,
        ]
        let stack = NSStackView(views: [field, swatchRow, separator] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space2
        stack.setCustomSpacing(Metrics.space4, after: field)
        stack.setCustomSpacing(Metrics.space4, after: swatchRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let p = Metrics.space5
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: p),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -p),
            field.heightAnchor.constraint(equalToConstant: Metrics.tabHeight),
            nameField.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: Metrics.space4),
            nameField.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -Metrics.space4),
            nameField.centerYAnchor.constraint(equalTo: field.centerYAnchor),
        ] + ([field, swatchRow, separator] + rows).map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
    }

    private func row(_ title: String, command: @escaping (TabGroupItem) -> TabGroupCommand) -> TabGroupEditorRow {
        let row = TabGroupEditorRow(title: title)
        row.onPress = { [weak self] in
            guard let self, let group = self.group else { return }
            self.commitName()
            self.onCommand?(command(group))
            self.dismiss()
        }
        return row
    }

    func configure(_ group: TabGroupItem) {
        let renamed = self.group?.id != group.id || nameField.currentEditor() == nil
        self.group = group
        if renamed { nameField.stringValue = group.name }
        for swatch in swatches { swatch.isChosen = swatch.color == group.colorToken }
        saveRow?.title = group.isSaved ? Strings.editorUnsave : Strings.editorSave
    }

    private func pick(_ color: GroupColor) {
        guard let group, group.colorToken != color else { return }
        onCommand?(.setColor(group.id, color))
    }

    private func commitName() {
        guard let group, nameField.stringValue != group.name else { return }
        self.group?.name = nameField.stringValue
        onCommand?(.rename(group.id, name: nameField.stringValue))
    }

    func present(below anchor: CGRect, parent: NSWindow) {
        dismissing = false
        if self.parent !== parent {
            self.parent?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
        }
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? .zero
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - Metrics.space2 - size.height)
        if let screen = parent.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + Metrics.space2), visible.maxX - size.width - Metrics.space2)
            origin.y = max(origin.y, visible.minY + Metrics.space2)
        }
        setFrame(CGRect(origin: origin, size: size), display: true)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        makeFirstResponder(nameField)
        styleFieldEditor()
        Motion.animateTimed(.fadeIn) { animator().alphaValue = 1 }
    }

    /// Gray selection and caret: the system accent (blue) never shows in chrome.
    private func styleFieldEditor() {
        guard let editor = nameField.currentEditor() as? NSTextView else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            editor.selectedTextAttributes = [.backgroundColor: Palette.selectionFill.blended(withFraction: 0.5, of: Palette.textSecondary) ?? Palette.selectionFill]
            editor.insertionPointColor = Palette.textPrimary
        }
    }

    func dismiss() {
        guard !dismissing, isVisible else { return }
        dismissing = true
        commitName()
        parent?.removeChildWindow(self)
        orderOut(nil)
        onClose?()
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    // Return commits the name and closes, as in Chrome.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            dismiss()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }
}
