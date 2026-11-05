public import AppKit
import CmuxNextCompat
import CmuxNextDesignTokens

/// The All Themes playground (Debug menu > All Themes Playground, DEV and NIGHTLY): every bundled
/// theme as the App Theme, one row each, every element drawn in its ink on its ground with its
/// contrast; a failing sample (under its minimum, or following the system appearance) is ringed red.
///
/// AppKit (plans/cmux-next/no-swiftui-DESIGN.md): a search field, a "failures only" checkbox and
/// the summary above a table of ``AllThemesPlaygroundRow``s. The table makes only the rows on
/// screen, and each row takes a value snapshot (the snapshot boundary rule), never the model.
public final class AllThemesPlaygroundView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let model: AllThemesPlaygroundModel
    private let search = NSTextField()
    private let failuresOnly = NSButton(checkboxWithTitle: AllThemesPlaygroundStrings.failuresOnly, target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    /// The shown entries, as the table last read them.
    private(set) var shown: [AllThemesPlaygroundEntry] = []
    // task-owner: the view's `following`, started when it joins a window and cancelled when it leaves.
    private var following: Task<Void, Never>?

    /// Shows `model`'s themes.
    /// - Parameter model: The playground's state; the view writes its query and filter.
    public init(model: AllThemesPlaygroundModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        build()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The number of rows the table shows.
    var rowCount: Int { table.numberOfRows }

    /// The summary line ("3 of 622 themes fail").
    var summaryText: String { summary.stringValue }

    private func build() {
        search.placeholderString = AllThemesPlaygroundStrings.search
        search.bezelStyle = .roundedBezel
        search.focusRingType = .none
        search.delegate = self
        search.setAccessibilityIdentifier("cmux.allThemesPlayground.search")
        search.translatesAutoresizingMaskIntoConstraints = false
        search.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        let searchWidth = search.widthAnchor.constraint(equalToConstant: 260)
        searchWidth.priority = .defaultLow
        searchWidth.isActive = true

        failuresOnly.target = self
        failuresOnly.action = #selector(failuresOnlyChanged)
        failuresOnly.setAccessibilityIdentifier("cmux.allThemesPlayground.failuresOnly")

        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [search, failuresOnly, spacer, summary])
        header.orientation = .horizontal
        header.spacing = 12
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("theme"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.gridStyleMask = []
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("cmux.allThemesPlayground.table")

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        following?.cancel()
        following = nil
        guard window != nil else { return }
        let model = model
        following = Task { [weak self] in
            for await _ in ObservationStream({ _ = model.shown; _ = model.failingCount; _ = model.entries.count }) {
                guard let self, !Task.isCancelled else { return }
                self.render()
            }
        }
    }

    /// Reads the model: the summary, the controls, and the rows the filter shows.
    func render() {
        summary.stringValue = AllThemesPlaygroundStrings.summary(failing: model.failingCount, total: model.entries.count)
        if search.stringValue != model.query { search.stringValue = model.query }
        failuresOnly.state = model.failuresOnly ? .on : .off
        let next = model.shown
        guard next != shown else { return }
        shown = next
        table.reloadData()
    }

    @objc private func failuresOnlyChanged() {
        model.failuresOnly = failuresOnly.state == .on
        render()
    }

    public func controlTextDidChange(_ notification: Notification) {
        model.query = search.stringValue
        render()
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard shown.indices.contains(row) else { return 1 }
        return AllThemesPlaygroundRow.height(of: shown[row], width: tableView.bounds.width)
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shown.indices.contains(row) else { return nil }
        let identifier = AllThemesPlaygroundRow.reuseIdentifier
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? AllThemesPlaygroundRow
            ?? AllThemesPlaygroundRow(identifier: identifier)
        view.entry = shown[row]
        return view
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    /// A new width rewraps every row's chips: the table asks each shown row its height again.
    public func tableViewColumnDidResize(_ notification: Notification) {
        guard !shown.isEmpty else { return }
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<shown.count))
    }
}
