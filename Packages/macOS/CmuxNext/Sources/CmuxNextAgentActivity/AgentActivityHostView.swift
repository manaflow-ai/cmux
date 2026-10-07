import AppKit
import CmuxNextDesign

/// Hosts the native AppKit Agent activity pane.
public final class AgentActivityHostView: NSView {
    public let model: AgentActivityModel
    public let nativeView: AgentActivityNativeView
    private let source: any AgentActivitySource

    /// Makes a native activity pane for an injected source and model.
    public init(model: AgentActivityModel, source: any AgentActivitySource) {
        self.model = model
        self.source = source
        nativeView = AgentActivityNativeView(model: model, source: source)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        nativeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nativeView)
        NSLayoutConstraint.activate([
            nativeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            nativeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            nativeView.topAnchor.constraint(equalTo: topAnchor),
            nativeView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        model.observeChanges { [weak nativeView] in nativeView?.reload() }
    }

    /// Compatibility initializer for prototype snapshot callers.
    public convenience init(model: AgentActivityModel, layoutOverride: AgentActivityLayout? = nil) {
        if let layoutOverride { model.layout = layoutOverride }
        self.init(model: model, source: AgentActivityMockSource())
    }

    /// The old prototype page remains bundled for resource compatibility.
    public static var bundledPage: URL? {
        Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "agent-activity")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Exposes the source for composition roots that install a control adapter.
    public var activitySource: any AgentActivitySource { source }
}

/// AppKit renderer for the activity pane. It uses native scroll views and
/// layers, while the model remains the single source of state.
public final class AgentActivityNativeView: NSView {
    private let model: AgentActivityModel
    private let sessionTable = NSTableView()
    private let eventTable = NSTableView()
    private let preview = NSImageView()
    private let filmstrip = AgentActivityThumbnailFilmstrip()
    private let title = NSTextField(labelWithString: AgentActivityStrings.title)
    private let stopAll = NSButton()
    private var flatSessions: [AgentActivitySession] = []
    private var displayedEvents: [AgentActivityEvent] = []

    init(model: AgentActivityModel, source: any AgentActivitySource) {
        self.model = model
        super.init(frame: .zero)
        build()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func reload() {
        guard Thread.isMainThread else { return }
        rebuildSessions()
        rebuildDetail()
    }

    private func build() {
        let toolbar = NSStackView(views: [title, NSView(), stopAll])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stopAll.title = AgentActivityStrings.stopAll
        stopAll.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: AgentActivityStrings.stopAll)
        stopAll.imagePosition = .imageLeading
        stopAll.bezelStyle = .rounded
        stopAll.target = self
        stopAll.action = #selector(stopAllPressed)

        sessionTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session")))
        sessionTable.headerView = nil
        sessionTable.rowHeight = 34
        sessionTable.delegate = self
        sessionTable.dataSource = self
        let sessionScroll = NSScrollView()
        sessionScroll.drawsBackground = false
        sessionScroll.hasVerticalScroller = true
        sessionScroll.documentView = sessionTable

        eventTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("event")))
        eventTable.headerView = nil
        eventTable.rowHeight = 24
        eventTable.delegate = self
        eventTable.dataSource = self
        let eventScroll = NSScrollView()
        eventScroll.drawsBackground = false
        eventScroll.hasVerticalScroller = true
        eventScroll.documentView = eventTable

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignCenter
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        preview.layer?.cornerRadius = 8
        filmstrip.heightAnchor.constraint(equalToConstant: 86).isActive = true

        let detail = NSStackView(views: [preview, filmstrip, eventScroll])
        detail.orientation = .vertical
        detail.alignment = .width
        detail.spacing = 8

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        let left = NSView()
        let leftStack = NSStackView(views: [sessionScroll])
        leftStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(leftStack)
        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: left.leadingAnchor), leftStack.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            leftStack.topAnchor.constraint(equalTo: left.topAnchor), leftStack.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 220), left.widthAnchor.constraint(equalToConstant: 280),
        ])
        split.addArrangedSubview(left)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.translatesAutoresizingMaskIntoConstraints = false

        addSubview(toolbar)
        addSubview(split)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor), toolbar.heightAnchor.constraint(equalToConstant: 38),
            split.leadingAnchor.constraint(equalTo: leadingAnchor), split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: toolbar.bottomAnchor), split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func rebuildSessions() {
        flatSessions = model.groups.flatMap(\.sessions)
        sessionTable.reloadData()
        if let selected = flatSessions.firstIndex(where: { $0.id == model.selectedSessionID }) {
            sessionTable.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
        stopAll.isEnabled = model.liveLocalCount > 0
    }

    private func rebuildDetail() {
        guard let session = model.selectedSession else {
            preview.image = nil
            filmstrip.configure(events: [], model: model)
            displayedEvents = []
            eventTable.reloadData()
            return
        }
        displayedEvents = model.selectedEvents.reversed()
        eventTable.reloadData()
        filmstrip.configure(events: model.selectedEvents, model: model)
        if let frame = model.currentFrameEvent?.displayFrame {
            Task { @MainActor [weak self, model] in self?.preview.image = await model.image(for: frame) }
        } else {
            preview.image = nil
        }
        title.stringValue = "\(AgentActivityStrings.title)  ·  \(session.agentName)"
    }

    @objc private func stopAllPressed() { model.stopAll() }
}

extension AgentActivityNativeView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sessionTable ? flatSessions.count : displayedEvents.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("cell"), owner: self) as? NSTableCellView)
            ?? NSTableCellView()
        cell.identifier = tableColumn?.identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.textField = label
        }
        if tableView === sessionTable {
            let session = flatSessions[row]
            cell.textField?.stringValue = "\(session.agentName)  ·  \(session.label)"
            cell.textField?.textColor = session.status.isLive ? .labelColor : .secondaryLabelColor
            cell.toolTip = AgentActivityStrings.status(session.status)
        } else {
            let event = displayedEvents[row]
            cell.textField?.stringValue = "\(AgentActivityFormat.time(event.time))  \(event.tool ?? event.kind.rawValue)"
            cell.textField?.textColor = event.ok ? .labelColor : .systemRed
            cell.toolTip = event.target
        }
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === sessionTable, table.selectedRow >= 0, table.selectedRow < flatSessions.count {
            model.select(session: flatSessions[table.selectedRow].id)
        } else if table === eventTable, table.selectedRow >= 0, table.selectedRow < displayedEvents.count {
            model.scrub(to: displayedEvents[table.selectedRow].seq)
        }
    }
}
