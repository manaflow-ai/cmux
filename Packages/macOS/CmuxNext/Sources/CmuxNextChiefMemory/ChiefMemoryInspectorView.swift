public import AppKit
public import CmuxNextDesign
import CmuxNextCompat

/// The built-in Memory Inspector: what the Chief reads (its view), each line opened down to its
/// messages, search, and the owner's edits, deletes and undo. One per Chief, in a pane tab.
///
/// AppKit (plans/cmux-next/no-swiftui-DESIGN.md): a header (counts, search, refresh), a banner
/// (error or read-only), then a split view with the line list and the detail column. It follows
/// the model and rebuilds a column only when what it shows changed; the edit text view keeps its
/// editor across updates.
///
/// ```swift
/// ChiefMemoryInspectorView(model: ChiefMemoryInspectorModel(source: source, confirmDelete: confirm))
/// ```
public final class ChiefMemoryInspectorView: NSView, NSSearchFieldDelegate, NSTextViewDelegate {
    private let model: ChiefMemoryInspectorModel
    private let counts = NSTextField(labelWithString: "")
    private let rebuilding = NSButton()
    private let search = NSSearchField()
    private let refresh = NSButton()
    private let banner = NSButton()
    private let list = NSStackView()
    private let detail = NSStackView()
    private var listKey: ListKey?
    private var detailKey: DetailKey?
    private var editor: NSTextView?
    private var observation: Task<Void, Never>?

    private struct ListKey: Equatable {
        let searching: Bool, lines: [ChiefMemoryLine], hits: [ChiefMemorySearchHit], selected: String?, stale: [String]
    }

    private struct DetailKey: Equatable {
        let trail: [String], node: ChiefMemoryNode?, editing: ChiefMemoryTarget?, changes: [ChiefMemoryChange]
        let editable: Bool?, stale: [String], busy: Bool
    }

    /// The view of `model`; it reads the memory when it is made.
    public init(model: ChiefMemoryInspectorModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        build()
        reload()
        observation = Task { [weak self, model] in
            for await _ in ObservationStream({ (model.status, model.lines, model.trail, model.detail, model.hits, model.changes,
                                                model.editing, model.error, model.busy, model.query) }) {
                self?.reload()
            }
        }
        // task-owner: the first read of the memory; ends when it is read
        Task { [model] in await model.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { observation?.cancel() }
    }

    /// The id of the delete dialog's Delete button.
    public static let deleteButton = "delete"

    /// The cmux dialog that confirms a delete (the app presents it over the tab).
    public static func deleteDialog(for target: ChiefMemoryTarget) -> CmuxDialogSpec {
        CmuxDialogSpec(title: ChiefMemoryStrings.deleteTitle, lines: [ChiefMemoryStrings.deleteMessage],
                       buttons: [.cancel(), CmuxDialogButton(id: deleteButton, title: ChiefMemoryStrings.deleteConfirm, role: .destructive)],
                       identifier: "chief-memory.delete")
    }

    // MARK: Build

    private static func scroll(_ stack: NSStackView, inset: CGFloat) -> NSScrollView {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let clip = ChiefMemoryClipView()
        clip.drawsBackground = false
        let scroll = NSScrollView()
        scroll.contentView = clip
        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
        return scroll
    }

    private func build() {
        counts.font = Typography.body
        counts.textColor = .secondaryLabelColor
        rebuilding.isBordered = false
        rebuilding.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        rebuilding.imagePosition = .imageLeading
        rebuilding.contentTintColor = .systemOrange
        rebuilding.font = Typography.caption
        search.placeholderString = ChiefMemoryStrings.search
        search.delegate = self
        search.target = self
        search.action = #selector(searchSubmitted)
        search.sendsWholeSearchString = true
        search.setAccessibilityIdentifier("chief-memory.search")
        search.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        refresh.isBordered = false
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refresh.target = self
        refresh.action = #selector(refreshClicked)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [counts, rebuilding, spacer, search, refresh])
        header.orientation = .horizontal
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        let divider = NSBox()
        divider.boxType = .separator
        banner.isBordered = false
        banner.imagePosition = .imageLeading
        banner.alignment = .left
        banner.font = Typography.body
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.1).cgColor
        banner.setAccessibilityIdentifier("chief-memory.banner")

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        let listScroll = Self.scroll(list, inset: 6)
        list.spacing = 2
        let detailScroll = Self.scroll(detail, inset: 12)
        detail.spacing = 12
        split.addArrangedSubview(listScroll)
        split.addArrangedSubview(detailScroll)
        listScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        detailScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)

        let column = NSStackView(views: [header, divider, banner, split])
        column.orientation = .vertical
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, divider, banner, split] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            banner.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
    }

    // MARK: Reload

    /// Brings every part of the inspector to the model now.
    func reload() {
        let status = model.status
        counts.isHidden = status == nil
        if let status { counts.stringValue = String(format: ChiefMemoryStrings.counts, Int(status.messages), Int(status.nodesBuilt)) }
        rebuilding.isHidden = status?.stale.isEmpty ?? true
        rebuilding.title = String(format: ChiefMemoryStrings.rebuilding, status?.stale.count ?? 0)
        if search.currentEditor() == nil, search.stringValue != model.query { search.stringValue = model.query }
        refresh.isEnabled = !model.busy
        if let error = model.error {
            showBanner(error, symbol: "exclamationmark.triangle")
        } else if status?.editable == false {
            showBanner(ChiefMemoryStrings.readOnly, symbol: "lock")
        } else {
            banner.isHidden = true
        }
        let stale = status?.stale ?? []
        let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty && !model.hits.isEmpty
        let listKey = ListKey(searching: searching, lines: model.lines, hits: model.hits, selected: model.trail.last, stale: stale)
        if listKey != self.listKey {
            self.listKey = listKey
            rebuildList(listKey)
        }
        let detailKey = DetailKey(trail: model.trail, node: model.detail, editing: model.editing, changes: model.changes,
                                  editable: status?.editable, stale: stale, busy: model.busy)
        if detailKey != self.detailKey {
            self.detailKey = detailKey
            rebuildDetail(detailKey)
        }
    }

    private func showBanner(_ text: String, symbol: String) {
        banner.isHidden = false
        banner.title = "  " + text
        banner.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private func replace(_ stack: NSStackView, with views: [NSView]) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for view in views {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -stack.edgeInsets.left - stack.edgeInsets.right).isActive = true
        }
    }

    private static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Typography.title
        return label
    }

    private func openAction(_ name: String) -> @MainActor () -> Void {
        { [model] in _ = Task { await model.open(name) } }
    }

    private func rebuildList(_ key: ListKey) {
        let stale = Set(key.stale)
        var views: [NSView] = [Self.heading(key.searching ? ChiefMemoryStrings.results : ChiefMemoryStrings.view)]
        if key.searching {
            views += key.hits.map { hit in
                ChiefMemoryLineRow(name: hit.name, detail: hit.type, text: hit.snippet, stale: stale.contains(hit.name),
                                   selected: key.selected == hit.name, open: openAction(hit.name))
            }
        } else {
            views += key.lines.reversed().map { line in
                ChiefMemoryLineRow(name: line.name, detail: "L\(line.level)", text: line.text ?? "…",
                                   stale: line.stale || stale.contains(line.name),
                                   selected: key.selected == line.name, open: openAction(line.name))
            }
        }
        replace(list, with: views)
    }

    private func rebuildDetail(_ key: DetailKey) {
        editor = nil
        var views: [NSView] = []
        if !key.trail.isEmpty {
            let back = NSButton(title: ChiefMemoryStrings.back, target: self, action: #selector(backClicked))
            back.bezelStyle = .push
            back.controlSize = .small
            let trail = NSTextField(labelWithString: key.trail.joined(separator: " › "))
            trail.font = .monospacedSystemFont(ofSize: TypeScale.caption, weight: TypeScale.regular)
            trail.textColor = .secondaryLabelColor
            trail.lineBreakMode = .byTruncatingHead
            let row = NSStackView(views: [back, trail])
            row.orientation = .horizontal
            row.spacing = 4
            views.append(row)
        }
        if let node = key.node {
            let nodeViews = NSStackView()
            nodeViews.orientation = .vertical
            nodeViews.alignment = .leading
            nodeViews.spacing = 12
            nodeViews.setAccessibilityIdentifier("chief-memory.detail")
            var parts: [NSView] = [section(ChiefMemoryStrings.summaryLine + " " + node.line.name, target: .line(node.line.name),
                                           text: node.line.text ?? "…", stale: model.isStale(node.line.name), editable: node.line.built, key: key)]
            if let message = node.message {
                parts.append(section(ChiefMemoryStrings.message + " \(message.id) · \(message.kind)", target: .message(message.id),
                                     text: message.text, stale: false, editable: true, key: key))
            }
            if !node.children.isEmpty {
                parts.append(Self.heading(ChiefMemoryStrings.covers))
                let stale = Set(key.stale)
                parts += node.children.map { child in
                    ChiefMemoryLineRow(name: child.name, detail: "L\(child.level)", text: child.text ?? "…",
                                       stale: stale.contains(child.name), selected: false, open: openAction(child.name))
                }
            }
            for part in parts {
                nodeViews.addArrangedSubview(part)
                part.widthAnchor.constraint(equalTo: nodeViews.widthAnchor).isActive = true
            }
            views.append(nodeViews)
        } else {
            let pick = NSTextField(labelWithString: ChiefMemoryStrings.pickLine)
            pick.textColor = .secondaryLabelColor
            views.append(pick)
        }
        let divider = NSBox()
        divider.boxType = .separator
        views.append(divider)
        views.append(changeList(key))
        replace(detail, with: views)
        if let editor { window?.makeFirstResponder(editor) }
    }

    private func section(_ title: String, target: ChiefMemoryTarget, text: String, stale: Bool, editable: Bool, key: DetailKey) -> NSView {
        let label = Self.heading(title)
        var top: [NSView] = [label]
        if stale {
            let badge = NSTextField(labelWithString: ChiefMemoryStrings.stale)
            badge.font = Typography.caption
            badge.textColor = .systemOrange
            top.append(badge)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        top.append(spacer)
        if editable, key.editable == true, key.editing != target {
            top.append(ChiefMemoryActionButton(ChiefMemoryStrings.edit) { [model] in model.beginEdit(target) })
            let delete = ChiefMemoryActionButton(ChiefMemoryStrings.delete) { [model] in _ = Task { await model.delete(target) } }
            delete.contentTintColor = .systemRed
            top.append(delete)
        }
        let header = NSStackView(views: top)
        header.orientation = .horizontal
        var parts: [NSView] = [header]
        if key.editing == target {
            let scroll = NSTextView.scrollableTextView()
            scroll.borderType = .bezelBorder
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            if let view = scroll.documentView as? NSTextView {
                view.font = Typography.body
                view.string = model.draft
                view.delegate = self
                view.isRichText = false
                view.setAccessibilityIdentifier("chief-memory.editor")
                editor = view
            }
            let cancel = ThemedBezelButton(title: ChiefMemoryStrings.cancel, target: self, action: #selector(cancelClicked))
            cancel.keyHint = .escape
            let save = ThemedDefaultButton(title: ChiefMemoryStrings.save, target: self, action: #selector(saveClicked))
            save.keyHint = .command("s")
            save.isEnabled = !key.busy && model.draft != text
            save.setAccessibilityIdentifier("chief-memory.save")
            let buttons = NSStackView(views: [NSView(), cancel, save])
            buttons.orientation = .horizontal
            parts += [scroll, buttons]
        } else {
            let body = NSTextField(wrappingLabelWithString: text)
            body.font = Typography.body
            body.isSelectable = true
            body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            parts.append(body)
        }
        let stack = NSStackView(views: parts)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for part in parts { part.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func changeList(_ key: DetailKey) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var top: [NSView] = [Self.heading(ChiefMemoryStrings.changes), spacer]
        if key.changes.contains(where: { !$0.undone }), key.editing == nil {
            let undo = ChiefMemoryActionButton(ChiefMemoryStrings.undo) { [model] in _ = Task { await model.undoLast() } }
            undo.keyEquivalent = "z"
            undo.keyEquivalentModifierMask = .command
            undo.setAccessibilityIdentifier("chief-memory.undoLast")
            top.append(undo)
        }
        let header = NSStackView(views: top)
        header.orientation = .horizontal
        var parts: [NSView] = [header]
        if key.changes.isEmpty {
            let none = NSTextField(labelWithString: ChiefMemoryStrings.noChanges)
            none.textColor = .secondaryLabelColor
            parts.append(none)
        }
        parts += key.changes.map { change in
            let id = change.id
            return ChiefMemoryChangeRow(change: change, undo: { [model] in _ = Task { await model.undo(id) } })
        }
        let stack = NSStackView(views: parts)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        for part in parts { part.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    // MARK: Actions

    public func controlTextDidChange(_ notification: Notification) {
        model.query = search.stringValue
    }

    public func textDidChange(_ notification: Notification) {
        guard let editor else { return }
        model.draft = editor.string
    }

    @objc private func searchSubmitted() {
        model.query = search.stringValue
        Task { [model] in await model.search() }
    }

    @objc private func refreshClicked() { Task { [model] in await model.reload() } }
    @objc private func backClicked() { Task { [model] in await model.back() } }
    @objc private func cancelClicked() { model.cancelEdit() }
    @objc private func saveClicked() { Task { [model] in await model.saveEdit() } }
}

/// A clip view with a top-left origin, so a column starts at the top.
private final class ChiefMemoryClipView: NSClipView {
    nonisolated override var isFlipped: Bool { true }
}
