import AppKit
import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Bounded inner scroll view for the shortcut list. Forwards a wheel event to
/// the enclosing page scroll view once the table is at its scroll limit so the
/// bounded box reads as one continuous page (the rest falls through to `super`).
final class ShortcutListScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        let y = contentView.bounds.origin.y
        let maxY = max(0, (documentView?.bounds.height ?? 0) - contentView.bounds.height)
        let canScrollUp = dy < 0 && y < maxY        // content moves up
        let canScrollDown = dy > 0 && y > 0          // content moves down
        if dy == 0 || canScrollUp || canScrollDown {
            super.scrollWheel(with: event)
            return
        }
        if let page = ancestorPageScrollView() {
            page.scrollWheel(with: event)            // forward unchanged at the limit
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// First enclosing `NSScrollView` above this one (the SwiftUI page scroll view).
    private func ancestorPageScrollView() -> NSScrollView? {
        var view = superview
        while let v = view {
            if let scroll = v as? NSScrollView, scroll !== self { return scroll }
            view = v.superview
        }
        return nil
    }
}

// MARK: - NSViewRepresentable

/// NSTableView-backed virtualized list of shortcut recorder rows. Mirrors the
/// FileExplorerPanelView structure: representable → container NSView holding an
/// NSScrollView+NSTableView, Coordinator as dataSource/delegate, updateNSView
/// reconciles. Chosen over NSOutlineView because the data is flat.
struct ShortcutListView: NSViewRepresentable {
    let model: ShortcutListModel
    let heightRevision: Int      // explicit input so updateNSView fires on banner toggles

    init(model: ShortcutListModel, heightRevision: Int) {
        self.model = model; self.heightRevision = heightRevision
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> ShortcutListContainerView {
        let container = ShortcutListContainerView()
        container.install(coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ nsView: ShortcutListContainerView, context: Context) {
        context.coordinator.model = model
        if heightRevision != context.coordinator.lastHeightRevision {
            let ids = model.consumeRemeasure()
            let actions = ShortcutAction.settingsVisibleActions
            let idx = IndexSet(actions.enumerated().filter { ids.contains($0.element.rawValue) }.map(\.offset))
            if !idx.isEmpty { context.coordinator.tableView?.noteHeightOfRows(withIndexesChanged: idx) }
            context.coordinator.lastHeightRevision = heightRevision
        }
    }

    static func dismantleNSView(_ nsView: ShortcutListContainerView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: ShortcutListModel
        weak var tableView: NSTableView?
        var lastHeightRevision = 0
        private var fontObserver: GlobalFontMagnificationChangeObserver?
        private let actions = ShortcutAction.settingsVisibleActions

        init(model: ShortcutListModel) {
            self.model = model; super.init()
            fontObserver = GlobalFontMagnificationChangeObserver { [weak self] in
                guard let self, let tv = self.tableView else { return }
                tv.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.actions.count))
            }
        }
        func tearDown() { fontObserver = nil }

        func numberOfRows(in tableView: NSTableView) -> Int { actions.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("ShortcutListCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ShortcutListCellView)
                ?? ShortcutListCellView(identifier: id)
            cell.configure(model: model, action: actions[row], isLast: row == actions.count - 1)
            return cell
        }
    }
}

// MARK: - Container

/// Container that owns the bounded scroll view + table (kept off the representable
/// so makeNSView returns a single named NSView, per house style).
final class ShortcutListContainerView: NSView {
    private let scrollView = ShortcutListScrollView()
    private let tableView = NSTableView()

    func install(coordinator: ShortcutListView.Coordinator) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.usesAutomaticRowHeights = true
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.tableView = tableView

        scrollView.drawsBackground = false
        // No inner scroller: the bounded table must read as part of the one
        // continuous Settings page (upstream has no inner scroll here). Wheel
        // events still scroll the table and forward to the page at its limits
        // (ShortcutListScrollView); the outer page scroller is the sole indicator.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.documentView = tableView

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}

// MARK: - Cell

/// Cell hosting one SwiftUI ShortcutListRowView. Reuses its hosting view + recorder
/// button across actions (the recorder's own updateNSView re-points it) — this is
/// the recycling that keeps window-open fast (~12 live buttons, not 166).
final class ShortcutListCellView: NSTableCellView {
    private var host: NSHostingView<ShortcutListRowView>?
    private var currentActionID: String?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero); self.identifier = identifier
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(model: ShortcutListModel, action: ShortcutAction, isLast: Bool) {
        // Reused for a different action: cancel any armed recording before re-pointing.
        if let prev = currentActionID, prev != action.rawValue { recorderHost()?.cancelRecordingIfActive() }
        currentActionID = action.rawValue
        let root = ShortcutListRowView(model: model, action: action, isLast: isLast)
        if let host {
            host.rootView = root
        } else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = .intrinsicContentSize
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor),
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            self.host = host
        }
    }

    /// Locate the RecorderHostButton in the hosted SwiftUI subtree (descendant search).
    private func recorderHost() -> RecorderHostButton? { findRecorder(in: self) }
    private func findRecorder(in view: NSView) -> RecorderHostButton? {
        if let r = view as? RecorderHostButton { return r }
        for sub in view.subviews { if let r = findRecorder(in: sub) { return r } }
        return nil
    }
}
