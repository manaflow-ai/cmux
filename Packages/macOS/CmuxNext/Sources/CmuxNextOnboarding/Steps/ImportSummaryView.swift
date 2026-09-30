import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// Counts as number-over-label cells.
final class ImportCountsView: NSStackView {
    private var cells: [ImportDataKind: (NSTextField, NSTextField)] = [:]

    init() {
        super.init(frame: .zero)
        spacing = Metrics.space6
        for kind in ImportStepModel.offeredKinds {
            let number = OnboardingLabel.make("0", font: Typography.title)
            let label = OnboardingLabel.make(OnboardingStrings.kind(kind), font: Typography.caption, color: Palette.textTertiary)
            let cell = NSStackView(views: [number, label])
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 0
            cells[kind] = (number, label)
            addArrangedSubview(cell)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ counts: ImportCounts) {
        let values: [ImportDataKind: Int] = [.bookmarks: counts.bookmarks, .history: counts.history,
                                             .openTabs: counts.openTabs, .extensions: counts.extensions]
        for (kind, cell) in cells {
            cell.0.stringValue = (values[kind] ?? 0).formatted()
        }
    }
}

/// After an import: open the imported tabs, and reinstall each extension
/// from the Chrome Web Store with one click.
final class ImportSummaryView: NSView {
    private let model: ImportStepModel
    private let openTabs = OnboardingButton(OnboardingStrings.openTabsNow, style: .secondary)
    private let list = NSStackView()
    private let listScroll = NSScrollView()
    private let extensionsHeader = OnboardingLabel.make(OnboardingStrings.extensionsTitle, font: Typography.header, color: Palette.textSecondary)
    private let extensionsDetail = OnboardingLabel.make(OnboardingStrings.extensionsDetail, font: Typography.caption, color: Palette.textTertiary, lines: 2)
    private var shownIDs: [String] = []
    private var buttons: [String: OnboardingButton] = [:]
    private var listHeight: NSLayoutConstraint?
    private var loop: RenderLoop?

    init(model: ImportStepModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        openTabs.onPress = { [weak model] in model?.openImportedTabs() }
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = Metrics.space2
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        listScroll.documentView = document
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.scrollerStyle = .overlay
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        let tabsRow = NSStackView(views: [openTabs, FlexibleSpace()])
        let stack = NSStackView(views: [tabsRow, extensionsHeader, extensionsDetail, listScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space4
        stack.setCustomSpacing(Metrics.space6, after: tabsRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            document.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor), list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor), list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            extensionsDetail.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func render() {
        guard case .finished(let summary) = model.phase else { return }
        openTabs.isHidden = summary.openTabs.isEmpty
        openTabs.title = model.tabsOpened ? OnboardingStrings.tabsOpened : OnboardingStrings.openTabsNow
        openTabs.isEnabled = !model.tabsOpened
        let extensions = summary.extensions
        extensionsHeader.isHidden = extensions.isEmpty
        extensionsDetail.isHidden = extensions.isEmpty
        listScroll.isHidden = extensions.isEmpty
        if extensions.map(\.id) != shownIDs {
            shownIDs = extensions.map(\.id)
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            buttons = [:]
            for item in extensions {
                let name = OnboardingLabel.make(item.name, font: Typography.body)
                let button = OnboardingButton(OnboardingStrings.install, style: .secondary)
                button.onPress = { [weak model] in model?.install(item) }
                buttons[item.id] = button
                let row = NSStackView(views: [name, FlexibleSpace(), button])
                row.spacing = Metrics.space4
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            // Up to four rows show; more scroll.
            listHeight?.isActive = false
            let visible = CGFloat(min(extensions.count, 4))
            listHeight = listScroll.heightAnchor.constraint(equalToConstant: visible * OnboardingMetrics.buttonHeight + max(0, visible - 1) * Metrics.space2)
            listHeight?.isActive = true
        }
        for (id, button) in buttons {
            let requested = model.installRequested.contains(id)
            button.title = requested ? OnboardingStrings.opened : OnboardingStrings.install
            button.style = requested ? .plain : .secondary
        }
    }
}
