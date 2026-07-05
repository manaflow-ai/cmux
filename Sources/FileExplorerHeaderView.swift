import AppKit
import CmuxFoundation

/// Pure AppKit header bar with folder icon, path label, and sort control.
final class FileExplorerHeaderView: NSView {
    private let iconView = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let sortButton = NSButton()
    private var heightConstraint: NSLayoutConstraint?
    private var displayPath = ""
    private var quickSearchQuery: String?
    private var sortOptions = FileExplorerSortOptions.defaultValue
    var onSelectSortKey: ((FileExplorerSortKey) -> Void)?
    var onSelectSortOrder: ((FileExplorerSortOrder) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor

        sortButton.translatesAutoresizingMaskIntoConstraints = false
        sortButton.isBordered = false
        sortButton.bezelStyle = .regularSquare
        sortButton.imagePosition = .imageOnly
        sortButton.contentTintColor = .secondaryLabelColor
        sortButton.focusRingType = .none
        sortButton.target = self
        sortButton.action = #selector(showSortMenu(_:))

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        applyFonts()
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(pathLabel)
        addSubview(sortButton)

        let heightConstraint = heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.secondaryBarHeight)
        self.heightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            heightConstraint,

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: sortButton.leadingAnchor, constant: -4),

            sortButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            sortButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            sortButton.widthAnchor.constraint(equalToConstant: 22),
            sortButton.heightAnchor.constraint(equalToConstant: 22),
        ])
        applyHeaderState()
    }

    func applyFonts() {
        pathLabel.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        heightConstraint?.constant = RightSidebarChromeMetrics.secondaryBarHeight
    }

    func update(displayPath: String, sortOptions: FileExplorerSortOptions) {
        guard self.displayPath != displayPath || self.sortOptions != sortOptions else { return }
        self.displayPath = displayPath
        self.sortOptions = sortOptions
        applyHeaderState()
    }

    func updateQuickSearch(query: String?) {
        guard quickSearchQuery != query else { return }
        quickSearchQuery = query
        applyHeaderState()
    }

    private func applyHeaderState() {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        if let quickSearchQuery {
            iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            pathLabel.stringValue = "/" + quickSearchQuery
            pathLabel.toolTip = pathLabel.stringValue
        } else {
            iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            pathLabel.stringValue = displayPath
            pathLabel.toolTip = displayPath
        }
        sortButton.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        sortButton.toolTip = String.localizedStringWithFormat(
            String(localized: "fileExplorer.sort.tooltip", defaultValue: "Sort: %@, %@"),
            sortOptions.key.localizedTitle,
            sortOptions.order.localizedTitle
        )
        sortButton.setAccessibilityLabel(
            String(localized: "fileExplorer.sort.accessibilityLabel", defaultValue: "Sort Files")
        )
    }

    @objc private func showSortMenu(_ sender: NSButton) {
        let menu = NSMenu()

        let sortByItem = NSMenuItem(
            title: String(localized: "fileExplorer.sort.menu.sortBy", defaultValue: "Sort By"),
            action: nil,
            keyEquivalent: ""
        )
        sortByItem.isEnabled = false
        menu.addItem(sortByItem)

        for key in FileExplorerSortKey.allCases {
            let item = NSMenuItem(title: key.localizedTitle, action: #selector(selectSortKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = key == sortOptions.key ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let orderItem = NSMenuItem(
            title: String(localized: "fileExplorer.sort.menu.order", defaultValue: "Order"),
            action: nil,
            keyEquivalent: ""
        )
        orderItem.isEnabled = false
        menu.addItem(orderItem)

        for order in FileExplorerSortOrder.allCases {
            let item = NSMenuItem(title: order.localizedTitle, action: #selector(selectSortOrder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = order.rawValue
            item.state = order == sortOptions.order ? .on : .off
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc private func selectSortKey(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let key = FileExplorerSortKey(rawValue: rawValue) else { return }
        onSelectSortKey?(key)
    }

    @objc private func selectSortOrder(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let order = FileExplorerSortOrder(rawValue: rawValue) else { return }
        onSelectSortOrder?(order)
    }
}
