import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign

/// The Todo page: a field that adds an item, then the workspace's checklist. AppKit
/// (plans/cmux-next/no-swiftui-DESIGN.md); rows rebuild only when the items or the edited item
/// change, and the add field keeps its editor across updates.
final class WorkspaceTodoPageView: NSView, NSTextFieldDelegate {
    private let model: WorkspaceTodoPageModel
    private let noWorkspace = NSTextField(labelWithString: WorkspaceChecklistStrings.noWorkspace)
    private let add = NSTextField()
    private let empty = NSTextField(labelWithString: WorkspaceChecklistStrings.empty)
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private var shown: (items: [WorkspaceChecklistItem], editing: String?)?
    private var observation: Task<Void, Never>?

    init(model: WorkspaceTodoPageModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        build()
        reload()
        observation = Task { [weak self, model] in
            for await _ in ObservationStream({ (model.shown == nil, model.items, model.editing, model.draft) }) {
                self?.reload()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { observation?.cancel() }
    }

    nonisolated override var isFlipped: Bool { true }

    private func build() {
        for label in [noWorkspace, empty] { label.textColor = .secondaryLabelColor; label.font = Typography.body }
        add.placeholderString = WorkspaceChecklistStrings.addPlaceholder
        add.font = Typography.body
        add.bezelStyle = .roundedBezel
        add.focusRingType = .none
        add.delegate = self
        add.target = self
        add.action = #selector(addSubmitted)
        add.setAccessibilityIdentifier("cmux.todo.add")
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let clip = WorkspaceTodoClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let column = NSStackView(views: [noWorkspace, add, empty, scroll])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let width = column.widthAnchor.constraint(equalTo: widthAnchor, constant: -40)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            width,
            add.widthAnchor.constraint(equalTo: column.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            list.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
    }

    /// Brings the page to the model now.
    func reload() {
        let hasWorkspace = model.shown != nil
        let items = model.items
        noWorkspace.isHidden = hasWorkspace
        add.isHidden = !hasWorkspace
        empty.isHidden = !hasWorkspace || !items.isEmpty
        scroll.isHidden = !hasWorkspace || items.isEmpty
        if add.currentEditor() == nil || model.draft.isEmpty, add.stringValue != model.draft { add.stringValue = model.draft }
        guard shown?.items != items || shown?.editing != model.editing else { return }
        shown = (items, model.editing)
        for view in list.arrangedSubviews { view.removeFromSuperview() }
        let actions = rowActions
        for item in items {
            let row = WorkspaceTodoRow(item: item, isEditing: model.editing == item.id, actions: actions)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        model.draft = add.stringValue
    }

    @objc private func addSubmitted() {
        model.draft = add.stringValue
        model.submitDraft()
        add.stringValue = model.draft
    }

    private var rowActions: WorkspaceTodoRowActions {
        let model = model
        return WorkspaceTodoRowActions(
            toggle: { model.toggle($0) },
            setState: { model.setState($0, $1) },
            beginEdit: { model.editing = $0 },
            commitEdit: { item, text in
                model.editing = nil
                model.edit(item, text: text)
            },
            cancelEdit: { model.editing = nil },
            attachImages: { model.attachImages($0) },
            remove: { model.remove($0) })
    }
}

/// A clip view with a top-left origin, so the list starts at the top.
private final class WorkspaceTodoClipView: NSClipView {
    nonisolated override var isFlipped: Bool { true }
}
