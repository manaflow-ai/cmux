import AppKit

@MainActor
final class SettingsShellViewController: NSSplitViewController {
    private static let selectedSectionDefaultsKey = "selectedSettingsSection"

    private let sidebarController: SettingsSidebarViewController
    private let detailController: SettingsDetailViewController

    init() {
        let storedSection = UserDefaults.standard.string(forKey: Self.selectedSectionDefaultsKey)
            .flatMap(SettingsSection.init(rawValue:)) ?? .general
        sidebarController = SettingsSidebarViewController(selectedSection: storedSection)
        detailController = SettingsDetailViewController(section: storedSection)
        super.init(nibName: nil, bundle: nil)
        sidebarController.onSelectSection = { [weak self] section in
            self?.select(section)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        sidebarItem.preferredThicknessFraction = 0.24

        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = 420

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        splitView.setPosition(230, ofDividerAt: 0)
    }

    private func select(_ section: SettingsSection) {
        detailController.section = section
        UserDefaults.standard.set(section.rawValue, forKey: Self.selectedSectionDefaultsKey)
    }
}

@MainActor
private final class SettingsSidebarViewController: NSViewController, NSSearchFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let initialSection: SettingsSection
    private var filteredSections = SettingsSection.allCases
    var onSelectSection: ((SettingsSection) -> Void)?

    init(selectedSection: SettingsSection) {
        initialSection = selectedSection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()

        searchField.placeholderString = String(localized: "settings.search.prompt", defaultValue: "Search")
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("settings.search")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 28
        tableView.style = .sourceList

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(
            labelWithString: String(localized: "settings.sidebar.title", defaultValue: "Settings")
        )
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(title)
        view.addSubview(searchField)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            searchField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        if let initialRow = filteredSections.firstIndex(of: initialSection) {
            tableView.selectRowIndexes(IndexSet(integer: initialRow), byExtendingSelection: false)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredSections = query.isEmpty
            ? SettingsSection.allCases
            : SettingsSection.allCases.filter { $0.searchText.localizedStandardContains(query) }
        tableView.reloadData()
        if let selected = filteredSections.first {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            onSelectSection?(selected)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredSections.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredSections.indices.contains(row) else { return nil }
        let section = filteredSections[row]
        let identifier = NSUserInterfaceItemIdentifier("SettingsSectionCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView)
            ?? makeCell(identifier: identifier)
        cell.textField?.stringValue = section.title
        cell.imageView?.image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: section.title)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard filteredSections.indices.contains(row) else { return }
        onSelectSection?(filteredSections[row])
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let imageView = NSImageView()
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = imageView
        cell.textField = label
        cell.addSubview(imageView)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
