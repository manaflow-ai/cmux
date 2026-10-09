import AppKit
import CmuxNextDesign
import QuartzCore

/// The workspace group editor (cx-rcby, Lawrence 2026-10-08: the Chrome tab
/// group bubble): a name field that opens focused with the name selected,
/// a row of color dots (none, then the theme's palette) and the group's
/// actions in sections. Opened from the group chip, its more button or a
/// right-click. Every edit goes out through the callbacks; the editor
/// never edits sidebar state.
@MainActor
final class SidebarGroupEditor {
    var onRename: ((GroupID, String) -> Void)?
    var onColor: ((GroupID, GroupColor) -> Void)?
    var onItem: ((GroupID, String) -> Void)?
    /// The editor closed, after any rename it committed.
    var onClose: ((GroupID) -> Void)?
    private var panel: SidebarGroupEditorPanel?
    private(set) var shownGroup: GroupID?
    /// A member of the shown group: the store may give a group the sidebar
    /// made another id, and the editor follows it.
    private var member: WorkspaceID?
    /// The groups the last update showed (`follow`).
    private var known: Set<GroupID> = []
    /// The group whose editor closed last, and the event time it closed at.
    private var lastClosed: (group: GroupID, time: TimeInterval)?
    /// The responder to give the keys back to when the editor closes.
    weak var previousResponder: NSResponder?

    var isVisible: Bool { shownGroup != nil }
    /// False in tests: the bubble is laid out but never put on screen.
    var ordersFront = true

    func show(_ group: SidebarGroup, items: [[SidebarGroupEditorItem]], anchor: CGRect, parent: NSWindow, themeAnchor: NSView) {
        if let shownGroup, shownGroup != group.id { hide() }
        let panel = panel ?? SidebarGroupEditorPanel()
        self.panel = panel
        panel.onRename = { [weak self] name in
            guard let self, let id = self.shownGroup else { return }
            self.onRename?(id, name)
        }
        panel.onColor = { [weak self] color in
            guard let self, let id = self.shownGroup else { return }
            self.onColor?(id, color)
        }
        panel.onItem = { [weak self] item in
            guard let self, let id = self.shownGroup else { return }
            self.onItem?(id, item)
        }
        panel.onClose = { [weak self] in
            guard let self, let id = self.shownGroup else { return }
            self.shownGroup = nil
            self.member = nil
            self.lastClosed = (id, NSApp.currentEvent?.timestamp ?? ProcessInfo.processInfo.systemUptime)
            self.onClose?(id)
        }
        shownGroup = group.id
        member = group.workspaces.first?.id
        panel.configure(group, items: items)
        panel.adoptThemeScope(of: themeAnchor)
        // A window off screen (tests, a hidden window) gets no bubble on screen.
        panel.present(below: anchor, parent: parent, ordersFront: ordersFront && parent.isVisible)
    }

    /// Keeps the open editor on its group after a sidebar update: the same
    /// group refreshes its color; a group the store re-identified is found
    /// by its member; a group that is gone closes the editor.
    func follow(_ groups: [GroupID: SidebarGroup]) {
        defer { known = Set(groups.keys) }
        guard let shown = shownGroup else { return }
        if let group = groups[shown] {
            panel?.refresh(group)
            if member == nil { member = group.workspaces.first?.id }
            return
        }
        // Only a group that just appeared can be the shown one under a new
        // id; a member dragged into another group ends the editor.
        if let member, let moved = groups.values.first(where: { !known.contains($0.id) && $0.workspaces.contains { $0.id == member } }) {
            shownGroup = moved.id
            panel?.refresh(moved)
            return
        }
        hide()
    }

    /// Whether the editor of `group` closed during the click that is
    /// happening now (the click made the sidebar's window key, which closes
    /// the bubble first): that click toggles it closed, it does not reopen it.
    func closedByThisClick(_ group: GroupID, at timestamp: TimeInterval?) -> Bool {
        guard let closed = lastClosed, closed.group == group, let timestamp else { return false }
        return timestamp - closed.time <= NSEvent.doubleClickInterval
    }

    func hide() {
        panel?.dismiss()
    }

    /// The editor's bubble, for tests and the real-app proof.
    var bubble: SidebarGroupEditorPanel? { panel }
}

/// The editor bubble: Liquid Glass (opaque under Reduce Transparency), in
/// the sidebar's theme scope.
final class SidebarGroupEditorPanel: ActiveAppKeyPanel, NSTextFieldDelegate {
    var onRename: ((String) -> Void)?
    var onColor: ((GroupColor) -> Void)?
    var onItem: ((String) -> Void)?
    var onClose: (() -> Void)?

    let nameField = NSTextField()
    private let field = NSView()
    private(set) var swatches: [SidebarGroupSwatchView] = []
    private let stack = NSStackView()
    private var name = ""
    private var fieldWidth: NSLayoutConstraint?
    private var dismissing = false
    /// Shown (on screen, or laid out in a test) and not yet dismissed.
    private(set) var isPresented = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let content = ThemeChangeView()
        let glass = Glass.makeOverlayPanel(content: content, cornerRadius: Metrics.panelCornerRadius)
        glass.translatesAutoresizingMaskIntoConstraints = true
        contentView = glass
        content.onThemeChange = { [weak self, weak glass] in
            glass?.applyTheme()
            self?.applyColors()
        }
        build(in: content)
        setAccessibilityLabel(GroupEditorStrings.editor)
        onKeyElsewhere = { [weak self] in self?.dismiss() }
    }

    override var canBecomeMain: Bool { false }

    /// About the Chrome bubble's width at the sidebar's type size.
    static var width: CGFloat { Metrics.space6 * 15 }

    private func build(in content: NSView) {
        nameField.placeholderString = GroupEditorStrings.namePlaceholder
        nameField.font = Typography.body
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.delegate = self
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setAccessibilityLabel(GroupEditorStrings.nameLabel)
        field.wantsLayer = true
        field.layer?.cornerRadius = Metrics.itemCornerRadius
        field.layer?.cornerCurve = .continuous
        nameField.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(nameField)

        swatches = GroupColor.editorOrder.map { color in
            let swatch = SidebarGroupSwatchView(color: color)
            swatch.onPick = { [weak self] picked in self?.pick(picked) }
            return swatch
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space1
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let p = Metrics.space4
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: p),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -p),
            field.heightAnchor.constraint(equalToConstant: Metrics.tabHeight),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.width - 2 * p),
            nameField.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: Metrics.space3),
            nameField.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -Metrics.space3),
            nameField.centerYAnchor.constraint(equalTo: field.centerYAnchor),
        ])
    }

    /// Lays out the name, the dots and the item sections for `group`.
    func configure(_ group: SidebarGroup, items: [[SidebarGroupEditorItem]]) {
        name = group.name
        nameField.stringValue = group.name
        for swatch in swatches { swatch.isChosen = swatch.color == group.color }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let dots = NSStackView(views: swatches)
        dots.spacing = Metrics.space1
        dots.distribution = .equalSpacing
        var views: [NSView] = [dots]
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(dots)
        stack.setCustomSpacing(Metrics.space3, after: field)
        var last: NSView = dots
        for section in items where !section.isEmpty {
            let separator = HairlineView()
            separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
            stack.setCustomSpacing(Metrics.space3, after: last)
            stack.addArrangedSubview(separator)
            stack.setCustomSpacing(Metrics.space2, after: separator)
            views.append(separator)
            for item in section {
                let row = SidebarGroupEditorRow(item)
                row.onPress = { [weak self] in self?.press(item.id) }
                stack.addArrangedSubview(row)
                views.append(row)
                last = row
            }
        }
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        if fieldWidth == nil {
            fieldWidth = field.widthAnchor.constraint(equalTo: stack.widthAnchor)
            fieldWidth?.isActive = true
        }
        applyColors()
    }

    /// The group changed while the editor is open: its color; its name only
    /// when the field is not being edited.
    func refresh(_ group: SidebarGroup) {
        for swatch in swatches { swatch.isChosen = swatch.color == group.color }
        if nameField.currentEditor() == nil {
            name = group.name
            nameField.stringValue = group.name
        }
    }

    private func applyColors() {
        guard let content = (contentView as? OverlaySurfaceView) else { return }
        content.performWithTheme {
            nameField.textColor = Palette.textPrimary
            field.layer?.backgroundColor = Palette.hoverFill.cgColor
            field.layer?.borderColor = Palette.focusRing.cgColor
            field.layer?.borderWidth = Metrics.dividerThickness
        }
        styleFieldEditor()
    }

    func pick(_ color: GroupColor) {
        for swatch in swatches { swatch.isChosen = swatch.color == color }
        onColor?(color)
    }

    func press(_ item: String) {
        commitName()
        onItem?(item)
        dismiss()
    }

    private func commitName() {
        let text = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != name else { return }
        name = text
        onRename?(text)
    }

    func present(below anchor: CGRect, parent: NSWindow, ordersFront: Bool = true) {
        dismissing = false
        isPresented = true
        if ordersFront, self.parent !== parent {
            self.parent?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
        }
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? .zero
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - Metrics.space1 - size.height)
        if let screen = parent.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + Metrics.space2), visible.maxX - size.width - Metrics.space2)
            // No room below: open above the chip.
            if origin.y < visible.minY + Metrics.space2 { origin.y = anchor.maxY + Metrics.space1 }
        }
        setFrame(CGRect(origin: origin, size: size), display: ordersFront)
        guard ordersFront else { return }
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
        styleFieldEditor()
        Motion.animateTimed(.fadeIn, in: contentView) { animator().alphaValue = 1 }
    }

    /// Gray selection and caret: the system accent (blue) never shows in chrome.
    private func styleFieldEditor() {
        guard let editor = nameField.currentEditor() as? NSTextView else { return }
        nameField.performWithTheme {
            editor.selectedTextAttributes = [.backgroundColor: Palette.textSelection]
            editor.insertionPointColor = Palette.textPrimary
        }
    }

    func dismiss() {
        guard !dismissing, isPresented else { return }
        dismissing = true
        isPresented = false
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

    /// Return commits the name and closes; Escape closes (a typed name is kept, like Chrome).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }
}
