import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextIcons

/// The Density Playground's window content: the density picker and its actions on top, the values of one group
/// (Vertical tabs, Horizontal tabs, Other) below, each a ``DensityPlaygroundRow`` with a slider, an exact field and a
/// reset.
///
/// AppKit (plans/cmux-next/no-swiftui-DESIGN.md). It draws at fixed sizes, not the density's: the window must stay
/// still while the sizes it tunes change under it. It follows the model through one ``ObservationStream`` (the draft,
/// the list, the notice, the save state and the theme) while it is in a window; its own actions render at once.
final class DensityPlaygroundView: NSView, NSTextFieldDelegate {
    /// The window's own sizes (a 4 pt grid), apart from the density being tuned.
    enum Size {
        static let pad: CGFloat = 16
        static let gap: CGFloat = 8
        static let rowHeight: CGFloat = 28
        static let slider: CGFloat = 168
        static let field: CGFloat = 56
        static let dot: CGFloat = 6
        static var body: NSFont { font(TypeScale.Base.detail) }
        static var label: NSFont { font(TypeScale.Base.detail) }
        static var labelChanged: NSFont { font(TypeScale.Base.detail, TypeScale.emphasis) }
        static var caption: NSFont { font(TypeScale.Base.caption) }
        static var captionDigits: NSFont { Typography.system(.monospacedDigit, size: TypeScale.Base.caption, weight: TypeScale.regular) }
        static var digits: NSFont { Typography.system(.monospacedDigit, size: TypeScale.Base.detail, weight: TypeScale.regular) }
        static var section: NSFont { font(TypeScale.Base.caption, TypeScale.emphasis) }

        /// The type scale's base sizes, not the density's: the window keeps its text while the density changes.
        private static func font(_ size: CGFloat, _ weight: NSFont.Weight = TypeScale.regular) -> NSFont {
            Typography.system(size: size, weight: weight)
        }
    }

    /// What the view follows: a change of any of these renders it again.
    private struct Observed: Equatable, Sendable {
        let draft: DensityTokens
        let customs: [DensityTokens]
        let notice: String?
        let hasUnsavedChanges: Bool
        let tokens: ThemeTokens
    }

    private let model: DensityPlaygroundModel
    private(set) var group: DensityTokenCatalog.Group = .verticalTabs
    private(set) var changedOnly = false
    private var confirmingDelete = false
    /// "Copied", until the next change of the draft (no timer: the window wakes nothing while idle).
    private var flash: String?
    /// The draft as the last render saw it.
    private var shownDraft: DensityTokens?

    private let densityLabel = NSTextField(labelWithString: DensityPlaygroundStrings.density)
    private lazy var picker = DensityPlaygroundButton(title: "", target: self, action: #selector(openPicker))
    let nameField = ThemedTextField()
    private lazy var nameBox = ThemedFieldBox(field: nameField, height: DensityPlaygroundButton.height)
    private lazy var duplicateButton = DensityPlaygroundButton(title: DensityPlaygroundStrings.duplicate, target: self, action: #selector(duplicate))
    private lazy var copyJSONButton = DensityPlaygroundButton(title: DensityPlaygroundStrings.copyJSON, target: self, action: #selector(copyJSON))
    private lazy var copySwiftButton = DensityPlaygroundButton(title: DensityPlaygroundStrings.copySwift, target: self, action: #selector(copySwift))
    private lazy var pasteButton = DensityPlaygroundButton(title: DensityPlaygroundStrings.pasteJSON, target: self, action: #selector(pasteJSON))
    private lazy var resetAllButton = DensityPlaygroundButton(title: DebugSettingsStrings.resetAll, target: self, action: #selector(resetAll))
    private lazy var deleteButton = DensityPlaygroundButton(title: DensityPlaygroundStrings.delete, target: self, action: #selector(deleteDraft))
    private let status = NSTextField(labelWithString: "")
    private let saveState = NSTextField(labelWithString: "")
    private lazy var groupControl = NSSegmentedControl(labels: DensityTokenCatalog.Group.allCases.map(DensityPlaygroundStrings.group),
                                                       trackingMode: .selectOne, target: self, action: #selector(groupChanged))
    private lazy var changedOnlyBox = ThemedCheckbox(checkboxWithTitle: DensityPlaygroundStrings.changedOnly, target: self,
                                                     action: #selector(changedOnlyChanged))
    private let separator = NSView()
    private let scroll = OverlayScrollView()
    private let list = NSStackView()
    /// One row per entry, made the first time its group shows and kept.
    private var rows: [String: DensityPlaygroundRow] = [:]
    private var sectionHeaders: [String: NSView] = [:]
    /// The sections and keys the list shows, as the last render laid them out.
    private var shownLayout: [[String]] = []
    // task-owner: the view's `following`, started when it joins a window and cancelled when it leaves.
    private var following: Task<Void, Never>?

    init(model: DensityPlaygroundModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 720))
        build()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated deinit { following?.cancel() }

    /// The window starts here, so Tab reaches the name and the value fields from the keyboard.
    override var acceptsFirstResponder: Bool { true }

    /// The rows the list shows, in order (tests).
    var shownRows: [DensityPlaygroundRow] { list.arrangedSubviews.compactMap { $0 as? DensityPlaygroundRow } }

    /// The status line under the actions.
    var statusText: String { status.stringValue }

    // MARK: Building

    private func build() {
        densityLabel.font = Size.body
        picker.trailingImage = NSImage.icon(.controlPopup, size: 10)
        picker.setAccessibilityLabel(DensityPlaygroundStrings.density)
        picker.setAccessibilityIdentifier("cmux.densityPlayground.picker")

        nameField.font = Size.body
        nameField.placeholderString = DensityPlaygroundStrings.name
        nameField.delegate = self
        nameField.setAccessibilityLabel(DensityPlaygroundStrings.name)
        nameField.setAccessibilityIdentifier("cmux.densityPlayground.name")
        nameBox.setContentHuggingPriority(.init(1), for: .horizontal)

        duplicateButton.setAccessibilityIdentifier("cmux.densityPlayground.duplicate")
        copyJSONButton.setAccessibilityIdentifier("cmux.densityPlayground.copyJSON")
        pasteButton.setAccessibilityIdentifier("cmux.densityPlayground.pasteJSON")
        resetAllButton.setAccessibilityIdentifier("cmux.densityPlayground.resetAll")
        deleteButton.setAccessibilityIdentifier("cmux.densityPlayground.delete")

        status.font = Size.caption
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 1
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        saveState.font = Size.captionDigits
        saveState.setContentCompressionResistancePriority(.required, for: .horizontal)

        groupControl.segmentStyle = .rounded
        groupControl.controlSize = .small
        groupControl.font = Size.body
        groupControl.selectedSegment = 0
        groupControl.themedToolTip = "⌘1 ⌘2 ⌘3"
        groupControl.setAccessibilityIdentifier("cmux.densityPlayground.group")
        changedOnlyBox.font = Size.body
        changedOnlyBox.controlSize = .small
        changedOnlyBox.setAccessibilityIdentifier("cmux.densityPlayground.changedOnly")

        let header = NSStackView(views: [
            line([densityLabel, picker, nameBox]),
            line([duplicateButton, copyJSONButton, copySwiftButton, pasteButton, spacer(), resetAllButton, deleteButton]),
            line([status, spacer(), saveState]),
            line([groupControl, spacer(), changedOnlyBox]),
        ])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = Size.gap
        header.translatesAutoresizingMaskIntoConstraints = false
        for view in header.arrangedSubviews { view.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true }

        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: Size.gap, right: 0)
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .automatic
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityIdentifier("cmux.densityPlayground.list")
        SystemScrollers.followThin(scroll)

        addSubview(header)
        addSubview(separator)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            // The titlebar is transparent and the content runs under it.
            header.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Size.pad),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Size.pad),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Size.gap + 4),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    private func line(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Size.gap
        return stack
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    // MARK: Following the model

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        following?.cancel()
        following = nil
        guard window != nil else { return }
        let model = model
        following = Task { [weak self] in
            let changes = ObservationStream {
                Observed(draft: model.draft, customs: model.customs, notice: model.notice,
                         hasUnsavedChanges: model.hasUnsavedChanges, tokens: SettingsTheme.shared.tokens)
            }
            for await _ in changes {
                guard let self, !Task.isCancelled else { return }
                self.render()
            }
        }
    }

    /// Reads the model and the view's own state into every control and row.
    func render() {
        let tokens = SettingsTheme.shared.tokens
        let draft = model.draft
        if draft != shownDraft {
            // A new density in the picker: its name in the field, Delete disarmed.
            if draft.id != shownDraft?.id {
                nameField.stringValue = model.name(draft)
                confirmingDelete = false
            }
            if shownDraft != nil { flash = nil }
            shownDraft = draft
        }

        picker.title = model.name(draft)
        resetAllButton.isEnabled = !model.isBuiltIn && model.changedCount > 0
        deleteButton.isHidden = model.isBuiltIn
        deleteButton.title = confirmingDelete ? DensityPlaygroundStrings.confirmDelete(model.name(draft)) : DensityPlaygroundStrings.delete
        deleteButton.ink = confirmingDelete ? .danger : .primary

        status.stringValue = statusLine
        status.textColor = (flash == nil && (model.notice != nil || model.statusNotice != nil) ? tokens.danger : tokens.textSecondary).nsColor
        saveState.isHidden = model.isBuiltIn
        saveState.stringValue = model.savesBlocked ? DensityPlaygroundStrings.notSaved
            : model.hasUnsavedChanges ? DensityPlaygroundStrings.saving : DensityPlaygroundStrings.saved
        saveState.textColor = tokens.textTertiary.nsColor

        let groupIndex = DensityTokenCatalog.Group.allCases.firstIndex(of: group) ?? 0
        if groupControl.selectedSegment != groupIndex { groupControl.selectedSegment = groupIndex }
        groupControl.selectedSegmentBezelColor = tokens.selectionFill.nsColor
        changedOnlyBox.state = changedOnly ? .on : .off

        densityLabel.textColor = tokens.textPrimary.nsColor
        separator.layer?.backgroundColor = Borders.drawsLines ? tokens.separator.cgColor : nil
        for button in [picker, duplicateButton, copyJSONButton, copySwiftButton, pasteButton, resetAllButton, deleteButton] {
            button.applyStyle()
        }
        renderList(tokens: tokens)
    }

    private var statusLine: String {
        if let flash { return flash }
        if let notice = model.notice ?? model.statusNotice { return notice }
        if model.isBuiltIn { return DensityPlaygroundStrings.builtInHint }
        return DensityPlaygroundStrings.changedCount(model.changedCount, base: model.name(model.base))
    }

    // MARK: Values

    private var sections: [(title: String, entries: [DensityTokenCatalog.Entry])] {
        var result: [(title: String, entries: [DensityTokenCatalog.Entry])] = []
        for entry in model.entries where entry.group == group && (!changedOnly || model.isChanged(entry)) {
            if let last = result.indices.last, result[last].title == entry.section {
                result[last].entries.append(entry)
            } else {
                result.append((entry.section, [entry]))
            }
        }
        return result
    }

    private func renderList(tokens: ThemeTokens) {
        let sections = sections
        let layout = sections.map { [$0.title] + $0.entries.map(\.key) }
        if layout != shownLayout {
            shownLayout = layout
            for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
            for (index, section) in sections.enumerated() {
                append(sectionHeader(section.title, at: index))
                for entry in section.entries {
                    let row = rows[entry.key] ?? DensityPlaygroundRow(model: model, entry: entry)
                    rows[entry.key] = row
                    append(row)
                }
            }
        }
        for view in list.arrangedSubviews {
            if let row = view as? DensityPlaygroundRow {
                row.update()
            } else {
                (view.subviews.first as? NSTextField)?.textColor = tokens.textSecondary.nsColor
            }
        }
    }

    private func append(_ view: NSView) {
        list.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    /// The heading of section `index` of the group shown, made once per group, place and title.
    private func sectionHeader(_ title: String, at index: Int) -> NSView {
        let key = "\(group)|\(index)|\(title)"
        if let made = sectionHeaders[key] { return made }
        let label = NSTextField(labelWithString: title)
        label.font = Size.section
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityRole(.staticText)
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: Size.pad - 4),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Size.pad),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -Size.pad),
        ])
        sectionHeaders[key] = container
        return container
    }

    // MARK: Actions

    /// The densities in a menu under the picker, the one in use checked.
    @objc private func openPicker() {
        let menu = NSMenu()
        for density in model.densities {
            let item = NSMenuItem(title: model.name(density), action: #selector(pickDensity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = density.id
            item.state = density.id == model.draft.id ? .on : .off
            menu.addItem(item)
        }
        menu.themeRows(in: themeScope)
        let current = menu.items.first { $0.state == .on }
        _ = menu.popUp(positioning: current, at: NSPoint(x: 0, y: picker.bounds.height), in: picker)
    }

    @objc private func pickDensity(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        model.select(id: id)
        render()
    }

    @objc private func duplicate() {
        model.duplicate()
        render()
    }

    @objc private func copyJSON() { copy(model.exportJSON) }

    @objc private func copySwift() { copy(model.exportSwift) }

    @objc private func pasteJSON() {
        model.importJSON(NSPasteboard.general.string(forType: .string) ?? "")
        render()
    }

    @objc private func resetAll() {
        model.resetAll()
        render()
    }

    /// Two presses, no dialog: the first arms it and names what goes.
    @objc private func deleteDraft() {
        if confirmingDelete {
            model.deleteDraft()
        } else {
            confirmingDelete = true
        }
        render()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // Says so until the next change (no timer: the window wakes nothing while idle).
        flash = DensityPlaygroundStrings.copied
        render()
    }

    @objc private func groupChanged() {
        let all = DensityTokenCatalog.Group.allCases
        guard all.indices.contains(groupControl.selectedSegment) else { return }
        select(group: all[groupControl.selectedSegment])
    }

    /// Shows `group`'s values.
    func select(group: DensityTokenCatalog.Group) {
        self.group = group
        render()
    }

    @objc private func changedOnlyChanged() {
        changedOnly = changedOnlyBox.state == .on
        render()
    }

    /// Command-1, -2 and -3 pick a group from the keyboard (a segmented control takes no focus by default).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let all = DensityTokenCatalog.Group.allCases
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let characters = event.charactersIgnoringModifiers, let digit = Int(characters), all.indices.contains(digit - 1) {
            select(group: all[digit - 1])
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Return or leaving the name field renames the density.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === nameField else { return }
        model.rename(nameField.stringValue)
        render()
    }
}

/// The list's document view: rows from the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
