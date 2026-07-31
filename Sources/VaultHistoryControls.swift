import AppKit
import CmuxFoundation

@MainActor
final class VaultHistoryControlsView: NSView, NSSearchFieldDelegate {
    let modeControl = NSSegmentedControl()
    let timeRangePopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    let sortOrderPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    let reloadButton = NSButton()
    let searchField = NSSearchField()

    var onModeChange: ((VaultHistoryMode) -> Void)?
    var onTimeRangeChange: ((VaultHistoryQuery.TimeRange) -> Void)?
    var onSortOrderChange: ((VaultHistoryQuery.SortOrder) -> Void)?
    var onSearchChange: ((String) -> Void)?
    var onReload: (() -> Void)?

    private let stackView = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
        configureModeControl()
        configureMenus()
        configureReloadButton()
        configureSearchField()
        buildLayout()
        applyFontMagnification()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        mode: VaultHistoryMode,
        timeRange: VaultHistoryQuery.TimeRange,
        sortOrder: VaultHistoryQuery.SortOrder,
        searchText: String,
        isReloadDisabled: Bool
    ) {
        modeControl.selectedSegment = VaultHistoryMode.allCases.firstIndex(of: mode) ?? 0
        selectItem(representing: timeRange.rawValue, in: timeRangePopUpButton)
        selectItem(representing: sortOrder.rawValue, in: sortOrderPopUpButton)
        updateMenuStates(selectedRawValue: timeRange.rawValue, in: timeRangePopUpButton)
        updateMenuStates(selectedRawValue: sortOrder.rawValue, in: sortOrderPopUpButton)
        if searchField.stringValue != searchText {
            searchField.stringValue = searchText
        }
        reloadButton.isEnabled = !isReloadDisabled
    }

    func applyFontMagnification() {
        modeControl.font = NSFont.systemFont(
            ofSize: GlobalFontMagnification.scaledSize(
                RightSidebarChromeControlStyle.labelSize
            )
        )
        let controlFont = NSFont.systemFont(
            ofSize: GlobalFontMagnification.scaledSize(
                RightSidebarChromeControlStyle.labelSize
            )
        )
        timeRangePopUpButton.font = controlFont
        sortOrderPopUpButton.font = controlFont
        searchField.font = controlFont
        invalidateIntrinsicContentSize()
    }

    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 0
        stackView.distribution = .fill
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configureModeControl() {
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.segmentCount = VaultHistoryMode.allCases.count
        modeControl.trackingMode = .selectOne
        modeControl.segmentStyle = .texturedRounded
        modeControl.controlSize = .small
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.setAccessibilityIdentifier("VaultHistoryModeControl")

        for (index, mode) in VaultHistoryMode.allCases.enumerated() {
            modeControl.setLabel(mode.label, forSegment: index)
            modeControl.setImage(
                NSImage(
                    systemSymbolName: mode.symbolName,
                    accessibilityDescription: mode.label
                ),
                forSegment: index
            )
            modeControl.setWidth(0, forSegment: index)
            modeControl.setToolTip(mode.label, forSegment: index)
        }
    }

    private func configureMenus() {
        configure(
            timeRangePopUpButton,
            items: VaultHistoryQuery.TimeRange.allCases.map {
                (rawValue: $0.rawValue, title: $0.label, symbolName: $0.symbolName)
            },
            action: #selector(timeRangeChanged(_:)),
            accessibilityIdentifier: "VaultHistoryTimeRangePicker",
            toolTip: String(
                localized: "vaultHistory.rangePicker.tooltip",
                defaultValue: "Filter history by time"
            )
        )
        configure(
            sortOrderPopUpButton,
            items: VaultHistoryQuery.SortOrder.allCases.map {
                (rawValue: $0.rawValue, title: $0.label, symbolName: $0.symbolName)
            },
            action: #selector(sortOrderChanged(_:)),
            accessibilityIdentifier: "VaultHistorySortPicker",
            toolTip: String(
                localized: "vaultHistory.sortPicker.tooltip",
                defaultValue: "Sort history"
            )
        )
    }

    private func configure(
        _ popUpButton: NSPopUpButton,
        items: [(rawValue: String, title: String, symbolName: String)],
        action: Selector,
        accessibilityIdentifier: String,
        toolTip: String
    ) {
        popUpButton.translatesAutoresizingMaskIntoConstraints = false
        popUpButton.controlSize = .small
        popUpButton.target = self
        popUpButton.action = action
        popUpButton.toolTip = toolTip
        popUpButton.setAccessibilityIdentifier(accessibilityIdentifier)
        popUpButton.removeAllItems()
        for item in items {
            popUpButton.addItem(withTitle: item.title)
            guard let menuItem = popUpButton.lastItem else { continue }
            menuItem.representedObject = item.rawValue
            menuItem.image = NSImage(
                systemSymbolName: item.symbolName,
                accessibilityDescription: item.title
            )
        }
        popUpButton.setContentHuggingPriority(.required, for: .horizontal)
        popUpButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureReloadButton() {
        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        reloadButton.isBordered = false
        reloadButton.bezelStyle = .accessoryBarAction
        reloadButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: String(
                localized: "vaultHistory.reload.tooltip",
                defaultValue: "Reload History"
            )
        )
        reloadButton.target = self
        reloadButton.action = #selector(reload(_:))
        reloadButton.toolTip = String(
            localized: "vaultHistory.reload.tooltip",
            defaultValue: "Reload History"
        )
        reloadButton.setAccessibilityIdentifier("VaultHistoryReloadButton")
        NSLayoutConstraint.activate([
            reloadButton.widthAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.controlHeight),
            reloadButton.heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.controlHeight),
        ])
    }

    private func configureSearchField() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.placeholderString = String(
            localized: "vaultHistory.search.placeholder",
            defaultValue: "Search history"
        )
        searchField.toolTip = searchField.placeholderString
        searchField.setAccessibilityIdentifier("VaultHistorySearchField")
    }

    private func buildLayout() {
        let modeRow = NSStackView(views: [modeControl])
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.distribution = .fill

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let filterRow = NSStackView(views: [
            timeRangePopUpButton,
            spacer,
            sortOrderPopUpButton,
            reloadButton,
        ])
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = 4

        let searchRow = NSStackView(views: [searchField])
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.distribution = .fill

        stackView.addArrangedSubview(VaultHistoryChromeBarView(contentView: modeRow))
        stackView.addArrangedSubview(VaultHistoryChromeBarView(contentView: filterRow))
        stackView.addArrangedSubview(VaultHistoryChromeBarView(contentView: searchRow))
    }

    private func selectItem(representing rawValue: String, in popUpButton: NSPopUpButton) {
        guard popUpButton.selectedItem?.representedObject as? String != rawValue,
              let item = popUpButton.itemArray.first(where: {
                  $0.representedObject as? String == rawValue
              }) else {
            return
        }
        popUpButton.select(item)
    }

    private func updateMenuStates(selectedRawValue: String, in popUpButton: NSPopUpButton) {
        for item in popUpButton.itemArray {
            item.state = (item.representedObject as? String == selectedRawValue) ? .on : .off
        }
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        guard VaultHistoryMode.allCases.indices.contains(sender.selectedSegment) else { return }
        onModeChange?(VaultHistoryMode.allCases[sender.selectedSegment])
    }

    @objc private func timeRangeChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let range = VaultHistoryQuery.TimeRange(rawValue: rawValue) else {
            return
        }
        onTimeRangeChange?(range)
    }

    @objc private func sortOrderChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let order = VaultHistoryQuery.SortOrder(rawValue: rawValue) else {
            return
        }
        onSortOrderChange?(order)
    }

    @objc private func reload(_ sender: NSButton) {
        _ = sender
        onReload?()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        onSearchChange?(searchField.stringValue)
    }
}

@MainActor
private final class VaultHistoryChromeBarView: NSView {
    init(contentView: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: RightSidebarChromeMetrics.secondaryBarHeight),
            contentView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: RightSidebarChromeMetrics.barHorizontalPadding
            ),
            contentView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -RightSidebarChromeMetrics.barHorizontalPadding
            ),
            contentView.topAnchor.constraint(
                equalTo: topAnchor,
                constant: RightSidebarChromeMetrics.barVerticalPadding
            ),
            contentView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -RightSidebarChromeMetrics.barVerticalPadding
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
