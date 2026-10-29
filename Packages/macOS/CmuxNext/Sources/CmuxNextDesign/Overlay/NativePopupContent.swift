import AppKit
import CmuxNextIcons

/// Native rows and editable controls. Domain mutations leave through the typed event callback.
@MainActor
final class NativePopupContent: NSView, NSTextFieldDelegate, NSSearchFieldDelegate {
    var emit: (NativePopupEventType, String?, String?) -> Void = { _, _, _ in }
    var openSubmenu: (NativePopupRow, NSView) -> Void = { _, _ in }
    var dismiss: () -> Void = {}
    var commit: () -> Void = {}
    private var model: NativePopupModel?
    private var rowViews: [(NativePopupRow, NSView)] = []
    private var targets: [NativePopupControlTarget] = []
    private var fields: [String: NSTextField] = [:]
    private var editableControls: [String: NSControl] = [:]
    private var selected: String?
    private var searchHasInput = false
    private(set) var selectionReason = "none"
    private var search: NSSearchField?
    private var title: ThemedLabel?
    private var pendingCompositionModel: NativePopupModel?
    private var typeahead = ""
    private var typeaheadTime: TimeInterval = 0
    private(set) var contentHeight: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func beginPresentation() {
        model = nil; selected = nil; selectionReason = "none"
        searchHasInput = false; pendingCompositionModel = nil
        typeahead = ""; typeaheadTime = 0
    }

    func update(_ next: NativePopupModel) {
        let focused = fields.first { $0.value.currentEditor() != nil }
        let focusedID = focused?.key ?? editableControls.first(where: { $0.value === window?.firstResponder })?.key
        if let editor = focused?.value.currentEditor() as? NSTextView, editor.hasMarkedText() {
            pendingCompositionModel = next
            return
        }
        let selection = (focused?.value.currentEditor() as? NSTextView)?.selectedRange()
        let priorSelection = next.id == model?.id ? selected : nil
        if next.id != model?.id || next.search?.id != model?.search?.id { searchHasInput = false }
        if next.rows != model?.rows || next.rail != model?.rail || next.footer != model?.footer || next.title != model?.title || next.search?.id != model?.search?.id {
            rebuild(next)
            if let focusedID, let replacement = editableControls[focusedID] ?? fields[focusedID] {
                window?.makeFirstResponder(replacement)
                if let selection, let editor = replacement.currentEditor() as? NSTextView {
                    editor.setSelectedRange(NSRange(location: min(selection.location, (editor.string as NSString).length), length: 0))
                }
            }
        }
        if let field = next.search, let search {
            // Keep descriptor changes live even when the stable search ID is unchanged.
            // Consumers update placeholder/disabled state while retaining IME focus.
            search.stringValue = field.value
            search.placeholderString = field.placeholder
            search.isEnabled = field.disabled != true
        }
        model = next
        let policy = next.search?.autoHighlight
        let auto = policy == nil || policy == .always || (policy == .first && searchHasInput && next.search?.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        selected = next.highlighted ?? priorSelection
        if next.highlighted == nil, selectionReason == "none", !auto { selected = nil }
        if selected != priorSelection { selectionReason = "none" }
        if !enabledRows.contains(where: { $0.0.id == selected }) {
            selected = auto ? enabledRows.first?.0.id : nil
            selectionReason = "none"
        }
        paintSelection()
        layoutRows()
    }

    func focusInitial() {
        if let search, search.isEnabled { window?.makeFirstResponder(search) }
        else if let row = enabledRows.first, row.0.slider != nil {
            window?.makeFirstResponder(editableControls[row.0.id] ?? self)
        } else { window?.makeFirstResponder(self) }
    }

    func rowView(id: String) -> NSView? { rowViews.first { $0.0.id == id }?.1 }

    private var enabledRows: [(NativePopupRow, NSView)] {
        rowViews.filter { !$0.0.isNoninteractive && $0.0.disabled != true }
    }

    private func rebuild(_ model: NativePopupModel) {
        subviews.forEach { $0.removeFromSuperview() }
        targets = []
        fields = [:]
        editableControls = [:]
        search = nil
        title = nil
        if let text = model.title, !text.isEmpty {
            let label = ThemedLabel(labelWithString: text)
            label.font = Typography.caption
            label.ink = .secondary
            title = label
            addSubview(label)
        }
        if let spec = model.search {
            let field = NSSearchField()
            field.focusRingType = .none
            field.stringValue = spec.value
            field.placeholderString = spec.placeholder
            field.isEnabled = spec.disabled != true
            field.font = Typography.body
            field.delegate = self
            field.sendsSearchStringImmediately = true
            field.setAccessibilityLabel(spec.placeholder)
            fields[spec.id] = field
            search = field
            addSubview(field)
        }
        let rows = (model.rail ?? []) + model.rows + (model.footer ?? [])
        let hasIcons = rows.contains { $0.icon != nil }
        rowViews = rows.map { row in (row, makeRow(row, hasIconColumn: hasIcons)) }
        rowViews.forEach { addSubview($0.1) }
    }

    private func makeRow(_ row: NativePopupRow, hasIconColumn: Bool) -> NSView {
        if row.kind == .separator { return NSBox.separator() }
        if row.kind == .textField {
            let field = NSTextField(string: row.value ?? "")
            field.focusRingType = .none
            field.placeholderString = row.placeholder ?? row.label
            field.font = Typography.body
            field.isEnabled = row.disabled != true
            field.delegate = self
            field.setAccessibilityLabel(row.label)
            fields[row.id] = field
            return field
        }
        if row.kind == .slider, let descriptor = row.slider {
            let view = NativePopupSliderView(row: row, descriptor: descriptor)
            view.change = { [weak self] value in self?.emit(.change, row.id, value) }
            view.commit = { [weak self] in self?.commit() }
            view.escape = { [weak self] in self?.dismiss() }
            editableControls[row.id] = view.slider
            return view
        }
        var trailing: [NSView] = []
        if let shortcut = row.shortcut { trailing.append(PopupRowView.shortcut(shortcut)) }
        if row.kind == .toggle {
            let control = NSSwitch()
            control.state = row.checked == true ? .on : .off
            control.isEnabled = row.disabled != true
            control.setAccessibilityLabel(row.label)
            bind(control) { [weak self] sender in
                guard let control = sender as? NSSwitch else { return }
                self?.emit(.change, row.id, control.state == .on ? "true" : "false")
            }
            editableControls[row.id] = control
            trailing.append(control)
        } else if row.kind == .choice {
            let control = NSSegmentedControl(labels: (row.options ?? []).map(\.label), trackingMode: .selectOne, target: nil, action: nil)
            for (index, option) in (row.options ?? []).enumerated() {
                control.setEnabled(option.disabled != true, forSegment: index)
                if option.id == row.value { control.selectedSegment = index }
            }
            control.isEnabled = row.disabled != true
            control.setAccessibilityLabel(row.label)
            bind(control) { [weak self] sender in
                guard let control = sender as? NSSegmentedControl,
                      let options = row.options, options.indices.contains(control.selectedSegment) else { return }
                self?.emit(.change, row.id, options[control.selectedSegment].id)
            }
            editableControls[row.id] = control
            trailing.append(control)
        } else if row.kind == .slider {
            let slider = NSSlider(value: Double(row.value ?? "") ?? row.minimum ?? 0,
                                  minValue: row.minimum ?? 0, maxValue: row.maximum ?? 1,
                                  target: nil, action: nil)
            slider.isContinuous = true
            slider.isEnabled = row.disabled != true
            slider.setAccessibilityLabel(row.label)
            let preferredWidth = slider.widthAnchor.constraint(equalToConstant: 120)
            preferredWidth.priority = .defaultHigh
            preferredWidth.isActive = true
            slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            bind(slider) { [weak self] sender in
                guard let slider = sender as? NSSlider else { return }
                let step = row.step ?? 0
                let value = step > 0 ? ((slider.doubleValue - slider.minValue) / step).rounded() * step + slider.minValue : slider.doubleValue
                self?.emit(.change, row.id, String(min(slider.maxValue, max(slider.minValue, value))))
            }
            editableControls[row.id] = slider
            trailing.append(slider)
        }
        for action in row.actions ?? [] {
            let button = NSButton(title: action.label, target: nil, action: nil)
            button.isBordered = false
            button.font = Typography.caption
            button.isEnabled = row.disabled != true && action.disabled != true
            if let icon = action.icon { button.image = NSImage.icon(IconName(icon), size: 14) }
            bind(button) { [weak self] _ in self?.emit(.pick, action.id, nil) }
            trailing.append(button)
        }
        if row.kind == .submenu {
            trailing.append(PopupRowView.shortcut("›"))
        }
        let accessory = trailing.isEmpty ? nil : NSStackView(views: trailing)
        accessory?.orientation = .horizontal
        accessory?.spacing = 6
        var layout = PopupRowView.Layout()
        layout.hoverFills = false
        layout.minHeight = row.description?.isEmpty == false ? 44 : PopupStyle.standard.rowHeight
        let mark = PopupRowView.checkMark(row.checked == true && row.kind != .toggle)
        let leading: NSView
        if hasIconColumn {
            let icon = NSImageView()
            if let name = row.icon { icon.image = NSImage.icon(IconName(name), size: 16) }
            let columns = NSStackView(views: [mark, icon])
            columns.orientation = .horizontal
            columns.spacing = 6
            columns.detachesHiddenViews = false
            mark.widthAnchor.constraint(equalToConstant: layout.leadingColumn).isActive = true
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            layout.leadingColumn += columns.spacing + 16
            leading = columns
        } else { leading = mark }
        let view = PopupRowView(leading: leading, title: row.label, subtitle: row.description,
                                trailing: accessory, layout: layout, interactive: !row.isNoninteractive)
        if row.kind == .slider, let accessory {
            // Preferred slider width yields to the actual padded row, including narrow rails.
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor,
                                                constant: layout.leading).isActive = true
        }
        view.isEnabled = row.disabled != true
        view.toolTip = row.disabledReason
        // Menu selection owns Return/Space. Embedded controls remain focusable, but a row
        // wrapper must not retain the keys after arrows move the menu highlight elsewhere.
        view.takesFocus = false
        view.setAccessibilityIdentifier(row.id)
        view.onHover = { [weak self] in
            self?.selected = row.id
            self?.selectionReason = "pointer"
            self?.paintSelection()
            self?.emit(.highlight, row.id, nil)
        }
        view.onActivate = { [weak self, weak view] in
            guard let self, let view else { return }
            activate(row, view: view)
        }
        return view
    }

    private func bind(_ control: NSControl, action: @escaping (NSControl) -> Void) {
        let target = NativePopupControlTarget(action)
        targets.append(target)
        control.target = target
        control.action = #selector(NativePopupControlTarget.controlChanged(_:))
    }

    private func activate(_ row: NativePopupRow, view: NSView) {
        guard row.disabled != true else { return }
        if let slider = view as? NativePopupSliderView { slider.slider.commitValue(true) }
        else if row.kind == .submenu { openSubmenu(row, view) }
        else if row.kind == .toggle { emit(.change, row.id, row.checked == true ? "false" : "true") }
        else if row.kind == .action { emit(.pick, row.id, nil) }
        else { window?.makeFirstResponder(editableControls[row.id] ?? view) }
    }

    private func paintSelection() {
        for (row, view) in rowViews { (view as? PopupRowView)?.isHighlighted = row.id == selected }
        if let view = rowViews.first(where: { $0.0.id == selected })?.1 { scrollToVisible(view.frame) }
    }

    override func layout() {
        super.layout()
        if let viewport = superview, frame.width != viewport.bounds.width {
            setFrameSize(NSSize(width: viewport.bounds.width, height: frame.height))
        }
        layoutRows()
    }

    private func layoutRows() {
        let inset = PopupStyle.standard.padding
        let railIDs = Set((model?.rail ?? []).map(\.id))
        let footerIDs = Set((model?.footer ?? []).map(\.id))
        let railWidth: CGFloat = railIDs.isEmpty ? 0 : CGFloat(model?.railWidth ?? 48)
        let bodyX = inset + railWidth
        let bodyWidth = max(0, bounds.width - bodyX - inset)
        var y = inset
        if let title { title.frame = NSRect(x: bodyX + 7, y: y, width: max(0, bodyWidth - 14), height: 24); y += 24 }
        if let search { search.frame = NSRect(x: bodyX + 4, y: y, width: max(0, bodyWidth - 8), height: 28); y += 34 }
        var railY = inset
        for (row, view) in rowViews where railIDs.contains(row.id) {
            let height: CGFloat = (view as? NativePopupSliderView)?.preferredHeight ?? 40
            view.frame = NSRect(x: inset, y: railY, width: railWidth, height: height)
            railY += height
        }
        for (row, view) in rowViews where !railIDs.contains(row.id) && !footerIDs.contains(row.id) {
            let height: CGFloat = (view as? NativePopupSliderView)?.preferredHeight ?? (row.kind == .separator ? 9 : row.kind == .textField ? 32 : row.description?.isEmpty == false ? 44 : PopupStyle.standard.rowHeight)
            view.frame = NSRect(x: bodyX, y: y, width: bodyWidth, height: height)
            y += height
        }
        y = max(y, railY)
        for (row, view) in rowViews where footerIDs.contains(row.id) {
            let height: CGFloat = (view as? NativePopupSliderView)?.preferredHeight ?? (row.kind == .separator ? 9 : row.description?.isEmpty == false ? 44 : PopupStyle.standard.rowHeight)
            view.frame = NSRect(x: bodyX, y: y, width: bodyWidth, height: height)
            y += height
        }
        contentHeight = y + inset
        if frame.height != contentHeight { setFrameSize(NSSize(width: frame.width, height: contentHeight)) }
    }

    override func keyDown(with event: NSEvent) {
        if handleKey(event.keyCode) { return }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let key = event.charactersIgnoringModifiers, key.count == 1,
           key.first?.isNumber == true,
           let row = enabledRows.first(where: { $0.0.shortcut == key }) {
            activate(row.0, view: row.1)
            return
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let text = event.characters, !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            typeahead = event.timestamp - typeaheadTime > 0.8 ? text : typeahead + text
            typeaheadTime = event.timestamp
            if let row = enabledRows.first(where: { $0.0.label.localizedStandardContains(typeahead) }) {
                selected = row.0.id; selectionReason = "keyboard"
                paintSelection()
            }
            return
        }
        super.keyDown(with: event)
    }

    private func handleKey(_ key: UInt16) -> Bool {
        let enabled = enabledRows
        if key == 53 { dismiss(); return true }
        if key == 125 || key == 126 {
            guard !enabled.isEmpty else { return true }
            let index = enabled.firstIndex(where: { $0.0.id == selected }) ?? (key == 125 ? -1 : 0)
            selected = enabled[(index + (key == 125 ? 1 : -1) + enabled.count) % enabled.count].0.id
            selectionReason = "keyboard"
            paintSelection()
            emit(.highlight, selected, nil)
            return true
        }
        if [36, 76, 49, 124].contains(key), let (row, view) = enabled.first(where: { $0.0.id == selected }) {
            if key != 124 || row.kind == .submenu { activate(row, view: view); return true }
        }
        return false
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let id = fields.first(where: { $0.value === field })?.key else { return }
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        let value = field.stringValue
        let isSearch = field === search
        if isSearch, model?.search?.autoHighlight != nil {
            searchHasInput = true
            selected = nil; selectionReason = "none"
            paintSelection()
        }
        if var pending = pendingCompositionModel {
            pendingCompositionModel = nil
            if isSearch {
                if pending.search?.id == id { pending.search?.value = value }
            } else {
                // The deferred descriptor predates the IME commit. Carry the committed
                // value into the matching field before rebuilding any native controls.
                let preserveCommit: (NativePopupRow) -> NativePopupRow = { row in
                    var row = row
                    if row.id == id, row.kind == .textField { row.value = value }
                    return row
                }
                pending.rows = pending.rows.map(preserveCommit)
                pending.rail = pending.rail?.map(preserveCommit)
                pending.footer = pending.footer?.map(preserveCommit)
            }
            update(pending)
        }
        emit(isSearch ? .search : .change, id, value)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): return handleKey(125)
        case #selector(NSResponder.moveUp(_:)): return handleKey(126)
        case #selector(NSResponder.insertTab(_:)):
            guard control === search, let search, search.isEnabled,
                  model?.search?.completeOnTab == true else { return false }
            guard let row = enabledRows.first(where: { $0.0.id == selected && $0.0.completion != nil })
                    ?? enabledRows.first(where: { $0.0.completion != nil }),
                  let completion = row.0.completion, completion != search.stringValue else { return false }
            emit(.complete, row.0.id, completion)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard control === search, let search, search.isEnabled else { return false }
            if model?.search?.submitOnReturn == true {
                let id = enabledRows.first(where: { $0.0.id == selected })?.0.id
                emit(.submit, id, search.stringValue)
                return true
            }
            return handleKey(36)
        case #selector(NSResponder.cancelOperation(_:)): return handleKey(53)
        default: return false
        }
    }
}
