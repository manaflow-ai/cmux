import AppKit
import CmuxNextIcons

/// Native rows and editable controls. Domain mutations leave through the typed event callback.
@MainActor
final class NativePopupContent: NSView, NSTextFieldDelegate, NSSearchFieldDelegate {
    var emit: (NativePopupEventType, String?, String?) -> Void = { _, _, _ in }
    var openSubmenu: (NativePopupRow, NSView) -> Void = { _, _ in }
    var dismiss: () -> Void = {}
    var commit: () -> Void = {}
    var model: NativePopupModel?
    var isPresentationActive = true
    var presentationIdentity = 0
    var rowViews: [(NativePopupRow, NSView)] = []
    var targets: [NativePopupControlTarget] = []
    var fields: [String: NSTextField] = [:]
    var inputState = NativePopupInputState()
    var allocateEditSequence: ((Int) -> Int)?
    var lastEditSequence: Int? { inputState.lastSequence }
    var emittingRevision: Int?
    var editableControls: [String: NSControl] = [:]
    var selected: String?
    var searchHasInput = false
    var selectionReason = "none"
    var search: NSSearchField?
    private var title: ThemedLabel?
    var pendingCompositionModel: NativePopupModel?
    /// An update that would rebuild the rows while AppKit tracks a slider: it applies when the
    /// drag ends, so the slider under the pointer is never replaced mid-drag.
    var pendingInteractionModel: NativePopupModel?
    /// The symbols and top placements' wrapping strip (its own scroll view past its row limit).
    var railStrip: NSScrollView?
    /// The hairline between a placed rail and the list.
    var railDivider: NSBox?
    var lastCheckedRail: String?
    private var typeahead = ""
    private var typeaheadTime: TimeInterval = 0
    private(set) var contentHeight: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func beginPresentation() {
        isPresentationActive = true
        presentationIdentity += 1
        model = nil; selected = nil; selectionReason = "none"
        searchHasInput = false; pendingCompositionModel = nil; pendingInteractionModel = nil
        typeahead = ""; typeaheadTime = 0
        inputState = NativePopupInputState()
        emittingRevision = nil
        // A replacement cannot inherit the old field editor or deferred IME commit.
        for field in fields.values { field.delegate = nil; _ = field.abortEditing() }
        subviews.forEach { $0.removeFromSuperview() }
        fields = [:]; editableControls = [:]; rowViews = []; targets = []
        search = nil; title = nil
        railStrip = nil; railDivider = nil; lastCheckedRail = nil
    }

    func update(_ incoming: NativePopupModel) {
        isPresentationActive = true
        if model?.id != incoming.id { inputState = NativePopupInputState() }
        let next = inputState.preservingLocalEdits(in: incoming)
        let focused = fields.first { $0.value.currentEditor() != nil }
        let focusedID = focused?.key ?? editableControls.first(where: { $0.value === window?.firstResponder })?.key
        var retireComposition = false
        if let editor = focused?.value.currentEditor() as? NSTextView, editor.hasMarkedText() {
            let keepsField: Bool
            if focused?.value === search {
                keepsField = next.search?.id == focusedID && next.search?.disabled != true
            } else {
                keepsField = ((next.rail ?? []) + next.rows + (next.footer ?? [])).contains {
                    $0.id == focusedID && $0.kind == .textField && $0.disabled != true
                }
            }
            if keepsField { pendingCompositionModel = next; return }
            pendingCompositionModel = nil
            if let focused {
                fields.removeValue(forKey: focused.key)
                focused.value.delegate = nil
                _ = focused.value.abortEditing()
            }
            retireComposition = true
        }
        pendingCompositionModel = nil
        let selection = (focused?.value.currentEditor() as? NSTextView)?.selectedRange()
        let reset = next.search?.autoHighlight != model?.search?.autoHighlight ||
            (next.search?.autoHighlight != nil && model?.search?.value.isEmpty == false && next.search?.value.isEmpty == true)
        if reset { selected = nil; selectionReason = "none"; searchHasInput = false }
        let priorSelection = next.id == model?.id ? selected : nil
        if next.id != model?.id || next.search?.id != model?.search?.id { searchHasInput = false }
        let retainedSliders = retainSliders(updating: next)
        if retireComposition || !retainedSliders && (next.rows != model?.rows || next.rail != model?.rail || next.footer != model?.footer) || next.railPlacement != model?.railPlacement || next.title != model?.title || next.search?.id != model?.search?.id {
            if !retireComposition, isTrackingSlider { pendingInteractionModel = next; return }
            pendingInteractionModel = nil
            rebuild(next)
            if let focusedID, let replacement = editableControls[focusedID] ?? fields[focusedID] {
                window?.makeFirstResponder(replacement)
            }
        }
        if let field = next.search, let search {
            // Keep descriptor changes live even when the stable search ID is unchanged.
            // Consumers update placeholder/disabled state while retaining IME focus.
            search.stringValue = field.value
            search.placeholderString = field.placeholder
            search.isEnabled = field.disabled != true
        }
        if let selection, let focusedID, let editor = fields[focusedID]?.currentEditor() as? NSTextView {
            let count = (editor.string as NSString).length
            let location = min(selection.location, count)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, count - location)))
        }
        model = next
        let policy = next.search?.autoHighlight
        let auto = policy == nil || policy == .always || (policy == .first && searchHasInput && next.search?.value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty == false)
        selected = next.highlighted ?? priorSelection
        if next.highlighted == nil, selectionReason == "none", !auto { selected = nil }
        if selected != priorSelection { selectionReason = "none" }
        if !(enabledRows + enabledRailRows).contains(where: { $0.0.id == selected }) {
            selected = auto ? enabledRows.first?.0.id : nil
            selectionReason = "none"
        }
        paintSelection()
        layoutRows()
    }

    func focusInitial() {
        if let search, search.isEnabled { window?.makeFirstResponder(search) }
        else if let row = enabledRows.first, row.0.kind == .slider {
            window?.makeFirstResponder(editableControls[row.0.id] ?? self)
        } else { window?.makeFirstResponder(self) }
    }

    func rowView(id: String) -> NSView? { rowViews.first { $0.0.id == id }?.1 }

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
        railStrip = nil
        railDivider = nil
        if let placement = model.railPlacement, let rail = model.rail, !rail.isEmpty {
            let rows = model.rows + (model.footer ?? [])
            let hasIcons = rows.contains { $0.icon != nil }
            rowViews = rail.map { ($0, makeRailTab($0, placement: placement)) } + rows.map { row in (row, makeRow(row, hasIconColumn: hasIcons)) }
            addPlacedRail(placement, rail: Set(rail.map(\.id)))
            return
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
            let owns = { [weak self, weak view] in self?.owns(view) == true }
            view.change = { [weak self] value in if owns() { self?.emit(.change, row.id, value) } }
            view.prepareCommit = { [weak self] in
                guard let self, owns() else { return nil }
                let identity = presentationIdentity
                return { [weak self] in
                    guard let self, isPresentationActive, presentationIdentity == identity else { return }
                    commit()
                }
            }
            view.escape = { [weak self] in if owns() { self?.dismiss() } }
            view.slider.interactionEnded = { [weak self] in self?.applyPendingInteraction() }
            view.slider.navigate = { [weak self] key in owns() ? (self?.navigateFromSlider(row.id, key: key) ?? false) : false }
            editableControls[row.id] = view.slider
            return view
        }
        // One right-hand column: controls, the side item, accessory actions, then the key.
        var trailing: [NSView] = []
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
            let slider = NativePopupTrackingSlider(value: Double(row.value ?? "") ?? row.minimum ?? 0,
                                  minValue: row.minimum ?? 0, maxValue: row.maximum ?? 1,
                                  target: nil, action: nil)
            slider.isContinuous = true
            slider.interactionEnded = { [weak self] in self?.applyPendingInteraction() }
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
        if row.kind == .action, row.opensChildren {
            trailing.append(sideItem(for: row))
        }
        for action in row.actions ?? [] {
            let button = NSButton(title: action.label, target: nil, action: nil)
            button.isBordered = false
            button.font = Typography.caption
            button.isEnabled = row.disabled != true && action.disabled != true
            if let icon = action.icon { button.image = NSImage.icon(IconName(icon), size: 14) }
            bind(button) { [weak self] _ in self?.emit(.pick, action.id, nil) }
            editableControls[action.id] = button
            trailing.append(button)
        }
        if let shortcut = row.shortcut { trailing.append(PopupRowView.shortcut(shortcut)) }
        if row.kind == .submenu {
            trailing.append(PopupRowView.shortcut([row.sideLabel, "›"].compactMap(\.self).joined(separator: " ")))
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
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: view.contentGuide.leadingAnchor).isActive = true
        }
        view.isEnabled = row.disabled != true
        view.themedToolTip = row.disabledReason
        // Menu selection owns Return/Space. Embedded controls remain focusable, but a row
        // wrapper must not retain the keys after arrows move the menu highlight elsewhere.
        view.takesFocus = false
        view.setAccessibilityIdentifier(row.id)
        view.onHover = { [weak self, weak view] in
            guard let self, let view, owns(view), view.isEnabled else { return }
            selected = row.id
            selectionReason = "pointer"
            paintSelection()
            emit(.highlight, row.id, nil)
        }
        view.onActivate = { [weak self, weak view] in
            guard let self, let view else { return }
            activate(row, view: view)
        }
        return view
    }

    func paintSelection() {
        for (row, view) in rowViews {
            (view as? PopupRowView)?.isHighlighted = row.id == selected
            (view as? NativePopupRailTab)?.isHighlighted = row.id == selected
        }
        if let view = rowViews.first(where: { $0.0.id == selected })?.1 {
            // A tab in the wrapping strip scrolls the strip, not the popup.
            if view.superview === self { scrollToVisible(view.frame) } else { view.scrollToVisible(view.bounds) }
        }
    }

    override func layout() {
        super.layout()
        if let viewport = superview, frame.width != viewport.bounds.width {
            setFrameSize(NSSize(width: viewport.bounds.width, height: frame.height))
        }
        layoutRows()
    }

    private func layoutRows() {
        if let placement = model?.railPlacement, model?.rail?.isEmpty == false {
            contentHeight = layoutPlacedRail(placement, title: title, search: search)
            if frame.height != contentHeight { setFrameSize(NSSize(width: frame.width, height: contentHeight)) }
            return
        }
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
}
