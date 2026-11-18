import AppKit
import CmuxNextIcons
import CmuxVisibleRows

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
    var title: ThemedLabel?
    /// Every row in display order, drawn or not, and each one's place (NativePopupContent+Window).
    var shownRows: [NativePopupRow] = []
    var shownIndex: [String: Int] = [:]
    /// The rows Up, Down, digits and typeahead move among, each one's place, and the digit keys.
    var listRows: [NativePopupRow] = []
    var listIndex: [String: Int] = [:]
    var shortcutRows: [String: String] = [:]
    /// The rail's tabs a click or Return (a highlighted Add harness) activates.
    var railRowIDs: Set<String> = []
    /// Row views alive, by row id: in each list only the rows in and around its viewport.
    var mounted: [String: NativePopupMountedRow] = [:]
    /// The views a rebuild may keep: an equal row's view is mounted again, the rest are dropped.
    var reusable: [String: NativePopupMountedRow] = [:]
    var rowTargets: [String: [NativePopupControlTarget]] = [:]
    /// The lists drawn by band (the popup's own, or one per column), and each row's list.
    var rowWindows: [NativePopupRowWindow] = []
    var windowOf: [String: Int] = [:]
    /// Each row's column, and each column's rows the keys reach (the columns layout).
    var columnOf: [String: Int] = [:]
    var columnListRows: [[NativePopupRow]] = []
    var columnListPosition: [String: Int] = [:]
    var isRealizing = false
    /// The row whose highlight was drawn last.
    var paintedID: String?
    /// The rows' work, for the visible-rows contract (NativePopupVisibleRowsTests).
    let listWork = ListWorkMeter()
    var pendingCompositionModel: NativePopupModel?
    /// An update that would rebuild the rows while AppKit tracks a slider: it applies when the
    /// drag ends, so the slider under the pointer is never replaced mid-drag.
    var pendingInteractionModel: NativePopupModel?
    /// The symbols and top placements' wrapping strip (its own scroll view past its row limit).
    var railStrip: NSScrollView?
    /// The hairline between a placed rail and the list.
    var railDivider: NSBox?
    var lastCheckedRail: String?
    /// The columns layout's parts (NativePopupContent+Columns): each column's scroll view, the
    /// search row's accessory, the hairlines, and the tallest the columns' band has been since the
    /// popup opened (it never shrinks while open).
    var columnViews: [NativePopupColumnView] = []
    var searchAccessoryTab: NativePopupRailTab?
    var columnsLines: [NSBox] = []
    var columnsBandFloor: CGFloat = 0
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
        columnViews = []; searchAccessoryTab = nil; columnsLines = []; columnsBandFloor = 0
        shownRows = []; shownIndex = [:]; listRows = []; listIndex = [:]; shortcutRows = [:]; railRowIDs = []
        mounted = [:]; reusable = [:]; rowTargets = [:]; rowWindows = []; windowOf = [:]; paintedID = nil
        columnOf = [:]; columnListRows = []; columnListPosition = [:]
    }

    func update(_ incoming: NativePopupModel) {
        isPresentationActive = true
        if model?.id != incoming.id { inputState = NativePopupInputState() }
        let next = inputState.preservingLocalEdits(in: incoming)
        let focused = fields.first { $0.value.currentEditor() != nil }
        let focusedControl = editableControls.first(where: { $0.value === window?.firstResponder })
        let focusedID = focused?.key ?? focusedControl?.key
        var retireComposition = false
        if let editor = focused?.value.currentEditor() as? NSTextView, editor.hasMarkedText() {
            let keepsField: Bool
            if focused?.value === search {
                keepsField = next.search?.id == focusedID && next.search?.disabled != true
            } else {
                keepsField = next.allRows.contains {
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
        // The page sends the whole model each revision: comparing it reads every row (no views).
        listWork.walked(next.allRows.count)
        let retainedSliders = retainSliders(updating: next)
        if retireComposition || !retainedSliders && (next.rows != model?.rows || next.rail != model?.rail || next.footer != model?.footer ||
            next.columns != model?.columns || next.searchAccessory != model?.searchAccessory) || next.railPlacement != model?.railPlacement || next.title != model?.title || next.search?.id != model?.search?.id {
            if !retireComposition, isTrackingSlider { pendingInteractionModel = next; return }
            pendingInteractionModel = nil
            // The rows' views read the new model as they are laid out and drawn.
            model = next
            rebuild(next, reusing: !retireComposition)
            // A kept row's control keeps the keys; a replacement, or a kept control moved into a new
            // column (AppKit took the keys when its old column left), takes them.
            if let focusedID, let replacement = editableControls[focusedID] ?? fields[focusedID],
               window?.firstResponder !== replacement, (replacement as? NSTextField)?.currentEditor() == nil {
                FocusRoute(.system, "a popup's content updated").moveKeyboard(in: window, to: replacement)
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
        if selectableRow(selected) == nil {
            selected = auto ? defaultRowID : nil
            selectionReason = "none"
        }
        paintSelection()
        layoutRows()
    }

    func focusInitial() {
        if let search, search.isEnabled { window?.makeFirstResponder(search) }
        else if let row = listRows.first, row.kind == .slider {
            _ = rowView(id: row.id)
            window?.makeFirstResponder(editableControls[row.id] ?? self)
        } else { window?.makeFirstResponder(self) }
    }

    /// The row's view; an undrawn list row is drawn first (a submenu's anchor, a pick).
    func rowView(id: String) -> NSView? {
        if let view = mounted[id]?.view { return view }
        guard let number = windowOf[id], let view = mount(id) else { return nil }
        orderRows(number)
        return view
    }

    /// `reusing`: every list keeps the views of rows that did not change.
    private func rebuild(_ model: NativePopupModel, reusing: Bool) {
        // Only list rows are kept; the few rows outside any list are made again.
        let keep = reusing ? mounted.filter { windowOf[$0.key] != nil } : [:]
        // A placed rail's tabs that did not change are kept too.
        let keptTabs = reusing ? Dictionary(rowViews.compactMap { row, view in (view as? NativePopupRailTab).map { (row.id, $0) } },
                                            uniquingKeysWith: { first, _ in first }) : [:]
        let kept = Set(keep.values.map { ObjectIdentifier($0.view) })
        let keptKeys = Set(keep.values.flatMap { Self.keys(of: $0.row) })
        subviews.filter { !kept.contains(ObjectIdentifier($0)) }.forEach { $0.removeFromSuperview() }
        targets = []
        fields = fields.filter { keptKeys.contains($0.key) }
        editableControls = editableControls.filter { keptKeys.contains($0.key) }
        rowTargets = rowTargets.filter { keep[$0.key] != nil }
        mounted = [:]
        reusable = keep
        rowViews = []
        rowWindows = []
        windowOf = [:]
        search = nil
        title = nil
        if let text = model.title, !text.isEmpty {
            let label = ThemedLabel(labelWithString: text)
            label.font = Typography.caption
            label.ink = .secondary
            title = label
            // First, before any row a rebuild kept (reading order).
            addSubview(label, positioned: .below, relativeTo: nil)
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
            if let title { addSubview(field, positioned: .above, relativeTo: title) } else { addSubview(field, positioned: .below, relativeTo: nil) }
        }
        railStrip = nil
        railDivider = nil
        columnViews = []
        searchAccessoryTab = nil
        columnsLines = []
        if model.hasColumns {
            addColumns(model)
            shownRows = (model.searchAccessory.map { [$0] } ?? []) + model.rows
                + (model.columns ?? []).flatMap(\.rows) + (model.footer ?? [])
        } else if let placement = model.railPlacement, let rail = model.rail, !rail.isEmpty {
            rowViews = rail.map { row in
                if let tab = keptTabs[row.id], tab.row == row, tab.placement == placement, tab.showsAccentBar { return (row, tab) }
                return (row, makeRailTab(row, placement: placement))
            }
            addPlacedRail(placement, rail: Set(rail.map(\.id)))
            let list = model.rows + (model.footer ?? [])
            addWindow(self, layout: .placed(model), rows: list)
            shownRows = rail + list
        } else {
            shownRows = (model.rail ?? []) + model.rows + (model.footer ?? [])
            addWindow(self, layout: .plain(model), rows: shownRows)
        }
        indexRows(model)
        // The rows outside any list are always drawn.
        for (row, view) in rowViews where mounted[row.id] == nil {
            mounted[row.id] = NativePopupMountedRow(row: row, view: view, hasIconColumn: false)
        }
        // Lays the lists out and draws the rows in their bands, taking back the kept views.
        layoutRows()
    }

    func makeRow(_ row: NativePopupRow, hasIconColumn: Bool) -> NSView {
        listWork.configured()
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

    /// Draws the highlight on the row that had it and the row that has it, no other.
    func paintSelection() {
        // A move touches the two rows involved; no move rechecks the selected row (a view a rebuild made).
        let touched = paintedID == selected ? [selected].compactMap(\.self) : HighlightTouch.rows(from: paintedID, to: selected)
        for id in touched {
            guard let view = mounted[id]?.view, highlight(view, id == selected) else { continue }
            listWork.configured()
        }
        paintedID = selected
        if let selected, let view = mounted[selected]?.view {
            // A tab in the wrapping strip, or a row in a column, scrolls its own list, not the popup.
            if view.superview === self { scrollToVisible(view.frame) } else { view.scrollToVisible(view.bounds) }
        } else if let selected, let number = windowOf[selected], let index = rowWindows[number].index[selected] {
            // Its list scrolls to it, and the scroll draws it.
            rowWindows[number].document?.scrollToVisible(rowWindows[number].frame(index))
        }
    }

    override func layout() {
        super.layout()
        if let viewport = superview, frame.width != viewport.bounds.width {
            setFrameSize(NSSize(width: viewport.bounds.width, height: frame.height))
        }
        layoutRows()
    }

    /// Lays the popup out, frames the mounted rows, then draws the rows that came into a band.
    private func layoutRows() {
        if model?.hasColumns == true {
            contentHeight = layoutColumns(title: title, search: search)
        } else if let placement = model?.railPlacement, model?.rail?.isEmpty == false {
            contentHeight = layoutPlacedRail(placement, title: title, search: search)
        } else if let layout = rowWindows.first?.layout, layout.parts.count > 1 {
            let body = layout.parts[1]
            // The plain list: its geometry is its row window's.
            let inset = PopupStyle.standard.padding
            let bodyWidth = max(0, bounds.width - body.x - inset)
            if let title { title.frame = NSRect(x: body.x + 7, y: inset, width: max(0, bodyWidth - 14), height: 24) }
            if let search {
                search.frame = NSRect(x: body.x + 4, y: inset + (title == nil ? 0 : 24), width: max(0, bodyWidth - 8), height: 28)
            }
            contentHeight = layout.height
        } else { return }
        if frame.height != contentHeight { setFrameSize(NSSize(width: frame.width, height: contentHeight)) }
        placeMountedRows()
        realizeVisibleRows()
    }

    override func keyDown(with event: NSEvent) {
        if handleKey(event.keyCode) { return }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let key = event.charactersIgnoringModifiers, key.count == 1,
           key.first?.isNumber == true,
           let id = shortcutRows[key], let row = listRow(id), let view = rowView(id: id) {
            activate(row, view: view)
            return
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let text = event.characters, !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            typeahead = event.timestamp - typeaheadTime > 0.8 ? text : typeahead + text
            typeaheadTime = event.timestamp
            if let row = listRows.first(where: { $0.label.localizedStandardContains(typeahead) }) {
                selected = row.id; selectionReason = "keyboard"
                paintSelection()
            }
            return
        }
        super.keyDown(with: event)
    }
}
