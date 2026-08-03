import AppKit
import CmuxFoundation
import Observation

enum CommandPaletteRenderTrailingLabelStyle: Equatable {
    case shortcut
    case kind
}

struct CommandPaletteRenderTrailingLabel: Equatable {
    let text: String
    let style: CommandPaletteRenderTrailingLabelStyle
}

struct CommandPaletteRenderResultRow: Identifiable, Equatable {
    let id: String
    let title: String
    let matchedIndices: Set<Int>
    let trailingLabel: CommandPaletteRenderTrailingLabel?
}

enum CommandPaletteScrollAnchor: Equatable {
    case top
    case bottom
}

struct CommandPaletteCommandListRenderState: Equatable {
    var resultsVersion: UInt64 = 0
    var emptyStateText: String = ""
    var listIdentity: String = "switcher"
    var rows: [CommandPaletteRenderResultRow] = []
    var selectedIndex: Int = 0
    var shouldShowEmptyState = false
    var scrollTargetID: String?
    var scrollTargetAnchor: CommandPaletteScrollAnchor?

    static let empty = CommandPaletteCommandListRenderState()
}

@MainActor
@Observable
final class CommandPaletteOverlayRenderModel {
    private(set) var commandList = CommandPaletteCommandListRenderState.empty
    @ObservationIgnored private var scheduledCommandListSequence: UInt64 = 0
    @ObservationIgnored private var appliedCommandListSequence: UInt64 = 0
    @ObservationIgnored private var appliedCommandListResultsVersion: UInt64 = 0

    func scheduleCommandListUpdate(_ state: CommandPaletteCommandListRenderState) {
        scheduledCommandListSequence &+= 1
        let sequence = scheduledCommandListSequence

        Task { @MainActor in
            await Task.yield()
            guard sequence >= appliedCommandListSequence else { return }
            guard state.resultsVersion >= appliedCommandListResultsVersion else { return }
            appliedCommandListSequence = sequence
            appliedCommandListResultsVersion = max(appliedCommandListResultsVersion, state.resultsVersion)
            guard commandList != state else { return }
            commandList = state
        }
    }
}

@MainActor
final class CommandPaletteCommandListNativeView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let listMaxHeight: CGFloat = 450
    private static let rowHeight: CGFloat = 24
    private static let emptyStateHeight: CGFloat = 44
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("CommandPaletteResult")

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var renderModel: CommandPaletteOverlayRenderModel
    private var state = CommandPaletteCommandListRenderState.empty
    private var onRunResult: (String) -> Void
    private var observationGeneration: UInt64 = 0

    init(
        renderModel: CommandPaletteOverlayRenderModel,
        onRunResult: @escaping (String) -> Void
    ) {
        self.renderModel = renderModel
        self.onRunResult = onRunResult
        super.init(frame: .zero)
        configureTable()
        observeRenderModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let contentHeight = state.rows.isEmpty
            ? Self.emptyStateHeight
            : CGFloat(state.rows.count) * Self.rowHeight
        return NSSize(width: NSView.noIntrinsicMetric, height: min(Self.listMaxHeight, contentHeight))
    }

    func update(
        renderModel: CommandPaletteOverlayRenderModel,
        onRunResult: @escaping (String) -> Void
    ) {
        self.onRunResult = onRunResult
        guard self.renderModel !== renderModel else {
            apply(renderModel.commandList)
            return
        }
        self.renderModel = renderModel
        observationGeneration &+= 1
        observeRenderModel()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        state.rows.isEmpty ? 1 : state.rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        state.rows.isEmpty ? Self.emptyStateHeight : Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !state.rows.isEmpty
    }

    func tableView(
        _ tableView: NSTableView,
        rowViewForRow row: Int
    ) -> NSTableRowView? {
        CommandPaletteResultRowView()
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if state.rows.isEmpty {
            let identifier = NSUserInterfaceItemIdentifier("CommandPaletteEmptyState")
            let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
                ?? NSTextField(labelWithString: "")
            field.identifier = identifier
            field.font = .systemFont(ofSize: 13)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.stringValue = state.shouldShowEmptyState ? state.emptyStateText : ""
            return field
        }

        guard state.rows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("CommandPaletteResultCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? CommandPaletteResultCellView)
            ?? CommandPaletteResultCellView(identifier: identifier)
        cell.configure(row: state.rows[row])
        cell.setAccessibilityIdentifier("CommandPaletteResultRow.\(row)")
        cell.setAccessibilityValue(state.rows[row].id)
        return cell
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = .zero
        tableView.rowHeight = Self.rowHeight
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(runClickedRow(_:))
        tableView.focusRingType = .none

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func observeRenderModel() {
        observationGeneration &+= 1
        let generation = observationGeneration
        let next = withObservationTracking {
            renderModel.commandList
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.observeRenderModel()
            }
        }
        apply(next)
    }

    private func apply(_ next: CommandPaletteCommandListRenderState) {
        guard state != next else { return }
        let identityChanged = state.listIdentity != next.listIdentity
        state = next
        tableView.reloadData()

        if next.rows.indices.contains(next.selectedIndex) {
            tableView.selectRowIndexes(IndexSet(integer: next.selectedIndex), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        invalidateIntrinsicContentSize()

        if identityChanged {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        scrollToTargetIfNeeded()
    }

    private func scrollToTargetIfNeeded() {
        guard let targetID = state.scrollTargetID,
              let row = state.rows.firstIndex(where: { $0.id == targetID }) else { return }
        let rowRect = tableView.rect(ofRow: row)
        let clipView = scrollView.contentView
        switch state.scrollTargetAnchor {
        case .top:
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: rowRect.minY))
            scrollView.reflectScrolledClipView(clipView)
        case .bottom:
            let maximumY = max(0, tableView.bounds.height - clipView.bounds.height)
            let targetY = min(maximumY, max(0, rowRect.maxY - clipView.bounds.height))
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
        case nil:
            tableView.scrollRowToVisible(row)
        }
    }

    @objc
    private func runClickedRow(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard state.rows.indices.contains(row) else { return }
        onRunResult(state.rows[row].id)
    }
}

private final class CommandPaletteResultRowView: NSTableRowView {
    private var tracking: NSTrackingArea?
    private var hovered = false {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovered, !isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        dirtyRect.fill()
    }
}

private final class CommandPaletteResultCellView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let trailingField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingField.lineBreakMode = .byTruncatingTail
        trailingField.maximumNumberOfLines = 1
        trailingField.textColor = .secondaryLabelColor
        trailingField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [titleField, trailingField])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(row: CommandPaletteRenderResultRow) {
        titleField.attributedStringValue = Self.highlightedTitle(row.title, indices: row.matchedIndices)
        if let trailing = row.trailingLabel {
            trailingField.isHidden = false
            trailingField.stringValue = trailing.text
            trailingField.font = .systemFont(
                ofSize: 11,
                weight: trailing.style == .shortcut ? .medium : .regular
            )
        } else {
            trailingField.isHidden = true
            trailingField.stringValue = ""
        }
    }

    private static func highlightedTitle(_ title: String, indices: Set<Int>) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        var characterIndex = 0
        var stringIndex = title.startIndex
        while stringIndex < title.endIndex {
            let next = title.index(after: stringIndex)
            if indices.contains(characterIndex) {
                result.addAttribute(
                    .foregroundColor,
                    value: NSColor.systemBlue,
                    range: NSRange(stringIndex..<next, in: title)
                )
            }
            characterIndex += 1
            stringIndex = next
        }
        return result
    }
}
