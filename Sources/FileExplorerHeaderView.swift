import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation

/// Pure AppKit header bar with folder icon, path label, sort control, and the Cloud-only retry button.
final class FileExplorerHeaderView: NSView {
    private let iconView = CmuxResolvedIconImageView()
    private let retryButton = NSButton()
    private var retry: (() -> Void)?
    private let pathLabel = NSTextField(labelWithString: "")
    private let sortButton = NSButton()
    private lazy var sortButtonTrailingToEdge = sortButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
    private lazy var sortButtonTrailingToRetry = sortButton.trailingAnchor.constraint(equalTo: retryButton.leadingAnchor, constant: -2)
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
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        retryButton.bezelStyle = .inline
        retryButton.isBordered = false
        retryButton.target = self
        retryButton.action = #selector(retryFiles)
        retryButton.toolTip = String(localized: "common.retry", defaultValue: "Retry")
        retryButton.setAccessibilityLabel(retryButton.toolTip)
        addSubview(retryButton)
        addSubview(sortButton)

        let heightConstraint = heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.secondaryBarHeight)
        self.heightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            heightConstraint,

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: RightSidebarChromeMetrics.contentIconLeadingPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.contentIconFrameSize),
            iconView.heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.contentIconFrameSize),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: RightSidebarChromeMetrics.contentIconTextSpacing),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: sortButton.leadingAnchor, constant: -4),

            sortButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            sortButton.widthAnchor.constraint(equalToConstant: 22),
            sortButton.heightAnchor.constraint(equalToConstant: 22),

            retryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.widthAnchor.constraint(equalToConstant: 18),
        ])
        applyRetryVisibility(false)
        applyHeaderState()
    }

    /// Keeps the sort button flush with the trailing edge when the Cloud-only retry button is hidden, and places it just before retry otherwise.
    private func applyRetryVisibility(_ isVisible: Bool) {
        retryButton.isHidden = !isVisible
        // Deactivate before activating so the two required trailing constraints never coexist.
        let (active, inactive) = isVisible
            ? (sortButtonTrailingToRetry, sortButtonTrailingToEdge)
            : (sortButtonTrailingToEdge, sortButtonTrailingToRetry)
        inactive.isActive = false
        active.isActive = true
    }

    func applyFonts() {
        pathLabel.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        heightConstraint?.constant = RightSidebarChromeMetrics.secondaryBarHeight
    }

    @objc private func retryFiles() { retry?() }

    func update(displayPath: String, sortOptions: FileExplorerSortOptions, retry: (() -> Void)? = nil) {
        self.retry = retry
        applyRetryVisibility(retry != nil)
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
        if let quickSearchQuery {
            iconView.apply(CmuxResolvedIconRequest(
                source: .systemSymbol(name: "magnifyingglass", accessibilityDescription: nil),
                size: NSSize(width: 14, height: 14),
                tintColor: .secondaryLabelColor,
                symbolWeight: .regular
            ))
            pathLabel.stringValue = "/" + quickSearchQuery
            pathLabel.toolTip = pathLabel.stringValue
        } else {
            iconView.apply(CmuxResolvedIconRequest(
                source: .systemSymbol(name: "folder.fill", accessibilityDescription: nil),
                size: NSSize(width: 14, height: 14),
                tintColor: .secondaryLabelColor,
                symbolWeight: .regular
            ))
            pathLabel.stringValue = displayPath
            pathLabel.toolTip = displayPath
        }
        sortButton.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "arrow.up.arrow.down", pointSize: 11, weight: .regular
        )
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
