import AppKit
import CMUXProjectModel
import CmuxFoundation
import Combine

@MainActor
private protocol ProjectTabController: AnyObject {
    var viewController: NSViewController { get }
    func refresh(model: ProjectModel)
}

/// Native AppKit presentation for a project surface. The controller owns the
/// project chrome and swaps native tab controllers without recreating active
/// search fields or table selections on every model mutation.
@MainActor
final class ProjectPanelNativeViewController: NSViewController, PanelContentControllerUpdating {
    private var configuration: PanelContentConfiguration
    private let panel: ProjectPanel
    private let contentContainer = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let schemePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let configurationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let reloadButton = NSButton()
    private let warningRow = NSStackView()
    private let warningLabel = NSTextField(labelWithString: "")
    private let tabControl = NSSegmentedControl()
    private var panelCancellable: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var tabController: (any ProjectTabController)?
    private var renderedTab: ProjectPanelTab?
    private var renderedModel: ProjectModel?

    init(configuration: PanelContentConfiguration) {
        guard let panel = configuration.panel as? ProjectPanel else {
            preconditionFailure("ProjectPanelNativeViewController requires ProjectPanel")
        }
        self.configuration = configuration
        self.panel = panel
        super.init(nibName: nil, bundle: nil)
        observePanel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = ProjectPanelFocusView()
        root.onFocus = { [weak self] in self?.configuration.onRequestPanelFocus() }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let chrome = makeChrome()
        chrome.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(chrome)
        root.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: chrome.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        refresh()
        if case .idle = panel.loadState {
            panel.reload()
        }
    }

    func update(configuration: PanelContentConfiguration) {
        self.configuration = configuration
        (view as? ProjectPanelFocusView)?.onFocus = { [weak self] in
            self?.configuration.onRequestPanelFocus()
        }
        refresh()
    }

    func teardownPanelContent() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func observePanel() {
        panelCancellable = panel.objectWillChange.sink { [weak self] in
            self?.scheduleRefresh()
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func makeChrome() -> NSView {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        schemePopup.target = self
        schemePopup.action = #selector(schemeChanged(_:))
        schemePopup.toolTip = String(localized: "project.scheme.tooltip", defaultValue: "Scheme")
        schemePopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        configurationPopup.target = self
        configurationPopup.action = #selector(configurationChanged(_:))
        configurationPopup.toolTip = String(localized: "project.configuration.tooltip", defaultValue: "Configuration")
        configurationPopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        reloadButton.bezelStyle = .inline
        reloadButton.isBordered = false
        reloadButton.target = self
        reloadButton.action = #selector(reloadProject(_:))
        reloadButton.toolTip = String(localized: "project.reload.tooltip", defaultValue: "Reload project")

        let icon = NSImageView(image: NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .labelColor
        let topRow = NSStackView(views: [icon, titleLabel, schemePopup, configurationPopup, projectFlexibleSpacer(), reloadButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10

        let warningIcon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
        warningIcon.contentTintColor = .systemOrange
        warningLabel.font = .systemFont(ofSize: 10)
        warningLabel.textColor = .systemOrange
        warningLabel.lineBreakMode = .byTruncatingTail
        let dismissWarning = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(dismissWarning(_:)))
        dismissWarning.bezelStyle = .inline
        dismissWarning.isBordered = false
        warningRow.orientation = .horizontal
        warningRow.alignment = .centerY
        warningRow.spacing = 6
        warningRow.addArrangedSubview(warningIcon)
        warningRow.addArrangedSubview(warningLabel)
        warningRow.addArrangedSubview(projectFlexibleSpacer())
        warningRow.addArrangedSubview(dismissWarning)

        tabControl.segmentCount = ProjectPanelTab.allCases.count
        tabControl.segmentStyle = .texturedRounded
        tabControl.trackingMode = .selectOne
        for (index, tab) in ProjectPanelTab.allCases.enumerated() {
            tabControl.setLabel(tab.displayLabel, forSegment: index)
        }
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))

        let separator = projectSeparator()
        let stack = NSStackView(views: [topRow, warningRow, tabControl, separator])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 4, right: 14)
        topRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        warningRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        return stack
    }

    private func refresh() {
        guard isViewLoaded else { return }
        titleLabel.stringValue = panel.displayTitle
        titleLabel.toolTip = panel.projectURL.path
        refreshPopups()
        warningRow.isHidden = panel.lastLoadError == nil
        if let error = panel.lastLoadError {
            warningLabel.stringValue = String.localizedStringWithFormat(
                String(localized: "project.reload.errorFormat", defaultValue: "Reload returned errors: %@"),
                error
            )
        }
        if let index = ProjectPanelTab.allCases.firstIndex(of: panel.activeTab) {
            tabControl.selectedSegment = index
        }

        switch panel.loadState {
        case .idle, .loading:
            installStatus(String.localizedStringWithFormat(
                String(localized: "project.loadingFormat", defaultValue: "Loading %@"),
                panel.displayTitle
            ))
        case let .failed(reason):
            installStatus(String.localizedStringWithFormat(
                String(localized: "project.failedFormat", defaultValue: "Failed: %@"),
                reason
            ))
        case let .loaded(model):
            if renderedTab != panel.activeTab || renderedModel != model || tabController == nil {
                installTab(panel.activeTab, model: model)
            } else {
                tabController?.refresh(model: model)
            }
        }
    }

    private func refreshPopups() {
        let schemes = allSchemes
        replaceItems(in: schemePopup, titles: schemes.map(\.name))
        if let selected = panel.selectedSchemeName {
            schemePopup.selectItem(withTitle: selected)
        }
        schemePopup.isHidden = schemes.isEmpty

        let configurations = allConfigurationNames
        replaceItems(in: configurationPopup, titles: configurations)
        if let selected = panel.selectedConfigurationName {
            configurationPopup.selectItem(withTitle: selected)
        }
        configurationPopup.isHidden = configurations.isEmpty
    }

    private func replaceItems(in popup: NSPopUpButton, titles: [String]) {
        guard popup.itemTitles != titles else { return }
        popup.removeAllItems()
        popup.addItems(withTitles: titles)
    }

    private var allSchemes: [SchemeSummary] {
        guard let model = panel.loadState.model else { return [] }
        var seen = Set<String>()
        return model.modules.flatMap(\.schemes).filter { seen.insert($0.name).inserted }
    }

    private var allConfigurationNames: [String] {
        guard let model = panel.loadState.model else { return [] }
        var seen = Set<String>()
        return model.modules.flatMap(\.configurationNames).filter { seen.insert($0).inserted }
    }

    private func installStatus(_ message: String) {
        renderedTab = nil
        renderedModel = nil
        tabController = nil
        installContent(ProjectStatusViewController(message: message))
    }

    private func installTab(_ tab: ProjectPanelTab, model: ProjectModel) {
        let controller: any ProjectTabController
        switch tab {
        case .files:
            controller = ProjectFilesNativeViewController(panel: panel, model: model)
        case .targets:
            controller = ProjectTargetsNativeViewController(panel: panel, model: model)
        case .buildSettings:
            controller = ProjectBuildSettingsNativeViewController(panel: panel, model: model)
        case .schemes:
            controller = ProjectSchemesNativeViewController(panel: panel, model: model)
        }
        renderedTab = tab
        renderedModel = model
        tabController = controller
        installContent(controller.viewController)
    }

    private func installContent(_ controller: NSViewController) {
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        addChild(controller)
        let childView = controller.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            childView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            childView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    @objc private func schemeChanged(_ sender: NSPopUpButton) {
        panel.selectedSchemeName = sender.titleOfSelectedItem
    }

    @objc private func configurationChanged(_ sender: NSPopUpButton) {
        panel.selectedConfigurationName = sender.titleOfSelectedItem
    }

    @objc private func reloadProject(_: Any?) {
        panel.reload()
    }

    @objc private func dismissWarning(_: Any?) {
        panel.lastLoadError = nil
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        guard ProjectPanelTab.allCases.indices.contains(sender.selectedSegment) else { return }
        panel.activeTab = ProjectPanelTab.allCases[sender.selectedSegment]
    }
}

@MainActor
private final class ProjectPanelFocusView: NSView {
    var onFocus: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        onFocus()
        super.mouseDown(with: event)
    }
}

@MainActor
private final class ProjectStatusViewController: NSViewController {
    private let message: String

    init(message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let label = projectLabel(message, size: 13, color: .secondaryLabelColor)
        let root = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }
}

@MainActor
private final class ProjectFilesNativeViewController: NSViewController, ProjectTabController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate
{
    private enum Row {
        case group(ProjectGroup, module: ProjectModule, depth: Int, expanded: Bool)
        case file(ProjectFileNode, module: ProjectModule, depth: Int)
    }

    private let panel: ProjectPanel
    private var model: ProjectModel
    private var rows: [Row] = []
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let detailContainer = NSView()
    var viewController: NSViewController { self }

    init(panel: ProjectPanel, model: ProjectModel) {
        self.panel = panel
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        searchField.placeholderString = String(localized: "project.files.filter.placeholder", defaultValue: "Filter files (e.g. AppDelegate)")
        searchField.stringValue = panel.filesSearchText
        searchField.delegate = self

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        let filterRow = NSStackView(views: [searchField, projectFlexibleSpacer(), countLabel])
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = 8
        filterRow.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project.files"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        let navigator = NSScrollView()
        navigator.documentView = tableView
        navigator.hasVerticalScroller = true
        navigator.drawsBackground = true
        navigator.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        navigator.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(navigator)
        split.addArrangedSubview(detailContainer)
        navigator.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        detailContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let root = NSStackView(views: [filterRow, projectSeparator(), split])
        root.orientation = .vertical
        root.spacing = 0
        filterRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        split.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        view = root
        refresh(model: model)
    }

    func refresh(model: ProjectModel) {
        self.model = model
        rows = flattenedRows()
        countLabel.stringValue = String(rows.count)
        tableView.reloadData()
        restoreSelection()
        refreshDetail()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        panel.filesSearchText = searchField.stringValue
        refresh(model: model)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard rows.indices.contains(index) else { return nil }
        switch rows[index] {
        case let .group(group, _, depth, expanded):
            return fileGroupCell(group: group, depth: depth, expanded: expanded)
        case let .file(file, module, depth):
            return fileCell(file: file, module: module, depth: depth)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case let .group(group, _, _, expanded):
            if expanded { panel.collapsedNodeIDs.insert(group.id) }
            else { panel.collapsedNodeIDs.remove(group.id) }
            refresh(model: model)
        case let .file(file, _, _):
            panel.selectedFilePath = file.resolvedPath?.path
            refreshDetail()
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
    }

    private func flattenedRows() -> [Row] {
        var result: [Row] = []
        let filter = panel.filesSearchText.lowercased()
        for module in model.modules {
            walk(node: .group(module.rootGroup), depth: 0, module: module, filter: filter, into: &result)
        }
        return result
    }

    private func walk(
        node: ProjectNodeKind,
        depth: Int,
        module: ProjectModule,
        filter: String,
        into result: inout [Row]
    ) {
        switch node {
        case let .group(group):
            let presentation = Self.presentationGroup(group, fallbackName: module.displayName)
            if !filter.isEmpty {
                let matches = Self.collectMatchingFiles(in: group, filter: filter)
                guard !matches.isEmpty else { return }
                result.append(.group(presentation, module: module, depth: depth, expanded: true))
                result.append(contentsOf: matches.map { .file($0, module: module, depth: depth + 1) })
                return
            }
            let expanded = !panel.collapsedNodeIDs.contains(group.id)
            result.append(.group(presentation, module: module, depth: depth, expanded: expanded))
            if expanded {
                for child in group.children {
                    walk(node: child, depth: depth + 1, module: module, filter: filter, into: &result)
                }
            }
        case let .file(file):
            result.append(.file(file, module: module, depth: depth))
        }
    }

    private static func presentationGroup(_ group: ProjectGroup, fallbackName: String) -> ProjectGroup {
        guard group.displayName.isEmpty || group.displayName == "(group)" else { return group }
        return ProjectGroup(
            id: group.id,
            displayName: fallbackName,
            resolvedPath: group.resolvedPath,
            style: group.style,
            children: group.children
        )
    }

    private static func collectMatchingFiles(in group: ProjectGroup, filter: String) -> [ProjectFileNode] {
        group.children.flatMap { child -> [ProjectFileNode] in
            switch child {
            case let .file(file):
                return file.displayName.lowercased().contains(filter) ? [file] : []
            case let .group(subgroup):
                return collectMatchingFiles(in: subgroup, filter: filter)
            }
        }
    }

    private func fileGroupCell(group: ProjectGroup, depth: Int, expanded: Bool) -> NSView {
        let cell = ProjectTableCellView()
        let chevron = projectSymbol(expanded ? "chevron.down" : "chevron.right", color: .secondaryLabelColor)
        let icon = projectSymbol(groupGlyph(group.style), color: .secondaryLabelColor)
        let label = projectLabel(group.displayName, size: 12)
        let stack = NSStackView(views: [chevron, icon, label, projectFlexibleSpacer()])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets.left = CGFloat(depth) * 14 + 6
        cell.install(stack)
        return cell
    }

    private func fileCell(file: ProjectFileNode, module: ProjectModule, depth: Int) -> NSView {
        let selected = panel.selectedFilePath == file.resolvedPath?.path
        let cell = ProjectTableCellView()
        cell.wantsLayer = true
        cell.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 12).isActive = true
        let icon = projectSymbol(fileGlyph(file.fileType), color: file.existsOnDisk ? .secondaryLabelColor : .systemOrange)
        let label = projectLabel(file.displayName, size: 12)
        if !file.existsOnDisk {
            let attributed = NSMutableAttributedString(string: file.displayName)
            attributed.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue], range: NSRange(location: 0, length: attributed.length))
            label.attributedStringValue = attributed
        }
        let stack = NSStackView(views: [spacer, icon, label, projectFlexibleSpacer()])
        for membership in file.memberships {
            let target = module.target(for: membership.targetID)
            stack.addArrangedSubview(projectBadge(target?.displayName ?? String(membership.targetID.rawValue.prefix(6)), color: .controlAccentColor))
        }
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets.left = CGFloat(depth) * 14 + 6
        stack.edgeInsets.right = 6
        cell.install(stack)
        return cell
    }

    private func restoreSelection() {
        guard let selectedPath = panel.selectedFilePath,
              let index = rows.firstIndex(where: {
                  if case let .file(file, _, _) = $0 { return file.resolvedPath?.path == selectedPath }
                  return false
              }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    private func refreshDetail() {
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        let detail: NSView
        if let path = panel.selectedFilePath,
           let found = findFile(path: path) {
            detail = fileDetail(file: found.file, module: found.module)
        } else {
            detail = projectEmptyDetail(
                systemImage: "doc.text.magnifyingglass",
                title: String(localized: "project.files.empty.title", defaultValue: "Select a file"),
                hint: String(localized: "project.files.empty.hint", defaultValue: "Pick any file in the tree to see its target memberships and on-disk path.")
            )
        }
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detail)
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detail.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detail.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
    }

    private func findFile(path: String) -> (file: ProjectFileNode, module: ProjectModule)? {
        for module in model.modules {
            if let file = Self.findFile(in: module.rootGroup, path: path) { return (file, module) }
        }
        return nil
    }

    private static func findFile(in group: ProjectGroup, path: String) -> ProjectFileNode? {
        for child in group.children {
            switch child {
            case let .file(file) where file.resolvedPath?.path == path:
                return file
            case let .group(subgroup):
                if let file = findFile(in: subgroup, path: path) { return file }
            default:
                break
            }
        }
        return nil
    }

    private func fileDetail(file: ProjectFileNode, module: ProjectModule) -> NSView {
        let stack = projectDetailStack()
        stack.addArrangedSubview(projectTitleRow(file.displayName, symbol: "doc.text"))
        if let path = file.resolvedPath?.path {
            stack.addArrangedSubview(projectDetailRow(String(localized: "project.files.path", defaultValue: "Path"), value: path, monospaced: true))
        }
        if let type = file.fileType {
            stack.addArrangedSubview(projectDetailRow(String(localized: "project.files.type", defaultValue: "Type"), value: type, monospaced: true))
        }
        stack.addArrangedSubview(projectDetailRow(
            String(localized: "project.files.onDisk", defaultValue: "On disk"),
            value: file.existsOnDisk
                ? String(localized: "project.common.yes", defaultValue: "Yes")
                : String(localized: "project.common.missing", defaultValue: "Missing")
        ))
        if !file.memberships.isEmpty {
            stack.addArrangedSubview(projectSectionLabel(String(localized: "project.files.targets", defaultValue: "Targets")))
            for membership in file.memberships {
                let target = module.target(for: membership.targetID)
                let name = target?.displayName ?? String(membership.targetID.rawValue.prefix(8))
                var value = "\(name) · \(membership.role.rawValue)"
                if !membership.compilerFlags.isEmpty {
                    value += " · \(membership.compilerFlags.joined(separator: " "))"
                }
                stack.addArrangedSubview(projectLabel(value, size: 11, color: .secondaryLabelColor, monospaced: !membership.compilerFlags.isEmpty))
            }
        }
        return projectVerticalScroll(stack)
    }

    private func groupGlyph(_ style: ProjectGroupStyle) -> String {
        switch style {
        case .logical: "folder"
        case .folderRef: "folder.fill"
        case .variant: "globe"
        case .synchronized: "folder.badge.gearshape"
        }
    }

    private func fileGlyph(_ fileType: String?) -> String {
        guard let fileType else { return "doc" }
        if fileType.contains("swift") { return "swift" }
        if fileType.contains("xcconfig") { return "doc.text" }
        if fileType.contains("plist") { return "list.bullet.rectangle" }
        if fileType.contains("asset") || fileType.contains("xcassets") { return "paintpalette" }
        if fileType.contains("storyboard") || fileType.contains("xib") { return "rectangle.3.group" }
        if fileType.contains("markdown") || fileType.contains("text") { return "doc.text" }
        if fileType.contains("entitlement") { return "lock.shield" }
        if fileType.contains("xcstrings") { return "globe" }
        return "doc"
    }
}

@MainActor
private final class ProjectTargetsNativeViewController: NSViewController, ProjectTabController,
    NSTableViewDataSource, NSTableViewDelegate
{
    private struct Entry {
        let module: ProjectModule
        let target: TargetSummary
    }

    private let panel: ProjectPanel
    private var model: ProjectModel
    private var entries: [Entry] = []
    private let tableView = NSTableView()
    private let detailContainer = NSView()
    var viewController: NSViewController { self }

    init(panel: ProjectPanel, model: ProjectModel) {
        self.panel = panel
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project.targets"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        let list = NSScrollView()
        list.documentView = tableView
        list.hasVerticalScroller = true
        list.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.4)
        list.drawsBackground = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(list)
        split.addArrangedSubview(detailContainer)
        list.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        detailContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        view = split
        refresh(model: model)
    }

    func refresh(model: ProjectModel) {
        self.model = model
        entries = model.modules.flatMap { module in module.targets.map { Entry(module: module, target: $0) } }
        tableView.reloadData()
        if let selected = panel.selectedTargetID,
           let index = entries.firstIndex(where: { $0.target.id == selected }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        refreshDetail()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let selected = panel.selectedTargetID == entry.target.id
        let cell = ProjectTableCellView()
        cell.wantsLayer = true
        cell.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor : NSColor.clear.cgColor
        let title = projectLabel(entry.target.displayName, size: 12, weight: .semibold)
        let metadataParts = [entry.target.deploymentTarget.map { "min: \($0)" },
                             entry.target.platforms.isEmpty ? nil : "platforms: \(entry.target.platforms.joined(separator: ","))",
                             "deps: \(entry.target.dependencies.count)"].compactMap { $0 }
        let metadata = projectLabel(metadataParts.joined(separator: " · "), size: 10, color: .secondaryLabelColor)
        let labels = NSStackView(views: [title, metadata])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let rowStack = NSStackView(views: [projectSymbol(targetGlyph(entry.target.productType), color: .controlAccentColor), labels, projectFlexibleSpacer(), projectBadge(entry.target.productType.rawValue, color: .secondaryLabelColor)])
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 8
        rowStack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        cell.install(rowStack)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = tableView.selectedRow
        guard entries.indices.contains(index) else { return }
        panel.selectedTargetID = entries[index].target.id
        tableView.reloadData()
        refreshDetail()
    }

    private func refreshDetail() {
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        let detail: NSView
        if let entry = entries.first(where: { $0.target.id == panel.selectedTargetID }) {
            detail = targetDetail(entry)
        } else {
            detail = projectEmptyDetail(
                systemImage: "shippingbox",
                title: String(localized: "project.targets.empty.title", defaultValue: "Select a target"),
                hint: String(localized: "project.targets.empty.hint", defaultValue: "Pick a target on the left to see its product type, dependencies, and configurations.")
            )
        }
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detail)
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detail.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detail.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
    }

    private func targetDetail(_ entry: Entry) -> NSView {
        let target = entry.target
        let module = entry.module
        let stack = projectDetailStack()
        stack.addArrangedSubview(projectTitleRow(target.displayName, symbol: targetGlyph(target.productType)))
        stack.addArrangedSubview(projectDetailRow(String(localized: "project.targets.product", defaultValue: "Product"), value: target.productType.rawValue))
        stack.addArrangedSubview(projectDetailRow(String(localized: "project.targets.platforms", defaultValue: "Platforms"), value: target.platforms.isEmpty ? "—" : target.platforms.joined(separator: ", ")))
        stack.addArrangedSubview(projectDetailRow(String(localized: "project.targets.deployMin", defaultValue: "Deploy min"), value: target.deploymentTarget ?? "—"))
        stack.addArrangedSubview(projectDetailRow(String(localized: "project.targets.bundleID", defaultValue: "Bundle ID"), value: target.bundleIdentifier ?? "—", monospaced: true))
        if !target.dependencies.isEmpty {
            stack.addArrangedSubview(projectSectionLabel(String(localized: "project.targets.dependencies", defaultValue: "Dependencies")))
            for dependency in target.dependencies {
                stack.addArrangedSubview(projectLabel(module.target(for: dependency)?.displayName ?? String(dependency.rawValue.prefix(10)), size: 12))
            }
        }
        let configurations = module.configurations.filter {
            if case let .target(id) = $0.scope { return id == target.id }
            return false
        }
        if !configurations.isEmpty {
            stack.addArrangedSubview(projectSectionLabel(String(localized: "project.targets.build", defaultValue: "Build")))
            let count = configurations.reduce(0) { $0 + $1.rawSettings.count }
            stack.addArrangedSubview(projectLabel("\(configurations.count) configurations · \(count) target overrides", size: 11, color: .secondaryLabelColor))
            let button = NSButton(title: String(localized: "project.targets.openBuildSettings", defaultValue: "Open in Build Settings"), target: self, action: #selector(openBuildSettings(_:)))
            button.bezelStyle = .inline
            button.contentTintColor = .controlAccentColor
            stack.addArrangedSubview(button)
        }
        return projectVerticalScroll(stack)
    }

    @objc private func openBuildSettings(_: Any?) {
        panel.activeTab = .buildSettings
    }
}

@MainActor
private final class ProjectBuildSettingsNativeViewController: NSViewController, ProjectTabController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate
{
    private struct Row {
        enum Winner { case target, project, none }
        let key: String
        let effective: String
        let target: String?
        let project: String?
        let winner: Winner
    }

    private let panel: ProjectPanel
    private var model: ProjectModel
    private var rows: [Row] = []
    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchField = NSSearchField()
    private let customizedOnly = NSButton(checkboxWithTitle: String(localized: "project.settings.customizedOnly", defaultValue: "Customized only"), target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    var viewController: NSViewController { self }

    init(panel: ProjectPanel, model: ProjectModel) {
        self.panel = panel
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        targetPopup.target = self
        targetPopup.action = #selector(targetChanged(_:))
        searchField.placeholderString = String(localized: "project.settings.filter.placeholder", defaultValue: "Filter settings")
        searchField.delegate = self
        searchField.stringValue = panel.settingsSearchText
        customizedOnly.target = self
        customizedOnly.action = #selector(customizedOnlyChanged(_:))
        customizedOnly.state = panel.settingsCustomizedOnly ? .on : .off
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        let controls = NSStackView(views: [projectLabel(String(localized: "project.settings.target", defaultValue: "Target"), size: 11, color: .secondaryLabelColor), targetPopup, projectFlexibleSpacer(), searchField, customizedOnly, countLabel])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

        let columns: [(String, String, CGFloat)] = [
            ("setting", String(localized: "project.settings.setting", defaultValue: "Setting"), 240),
            ("effective", String(localized: "project.settings.effective", defaultValue: "Effective"), 170),
            ("target", String(localized: "project.settings.targetColumn", defaultValue: "Target"), 170),
            ("project", String(localized: "project.settings.projectColumn", defaultValue: "Project"), 170),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = 100
            column.resizingMask = [.userResizingMask]
            tableView.addTableColumn(column)
        }
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true

        let root = NSStackView(views: [controls, projectSeparator(), scroll])
        root.orientation = .vertical
        root.spacing = 0
        controls.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        view = root
        refresh(model: model)
    }

    func refresh(model: ProjectModel) {
        self.model = model
        let targets = selectedModule?.targets ?? model.modules.first?.targets ?? []
        let titles = targets.map(\.displayName)
        if targetPopup.itemTitles != titles {
            targetPopup.removeAllItems()
            targetPopup.addItems(withTitles: titles)
            for (item, target) in zip(targetPopup.itemArray, targets) {
                item.representedObject = target.id.rawValue
            }
        }
        if let selected = panel.selectedTargetID,
           let index = targets.firstIndex(where: { $0.id == selected }) {
            targetPopup.selectItem(at: index)
        }
        rows = buildRows()
        countLabel.stringValue = String.localizedStringWithFormat(
            String(localized: "project.settings.countFormat", defaultValue: "%d settings"),
            rows.count
        )
        customizedOnly.state = panel.settingsCustomizedOnly ? .on : .off
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard rows.indices.contains(index), let identifier = tableColumn?.identifier.rawValue else { return nil }
        let row = rows[index]
        let value: String
        let color: NSColor
        switch identifier {
        case "setting":
            value = row.key
            color = row.winner == .none ? .secondaryLabelColor : .labelColor
        case "effective":
            value = row.effective
            color = .labelColor
        case "target":
            value = row.target ?? "—"
            color = row.winner == .target ? .controlAccentColor : .secondaryLabelColor
        default:
            value = row.project ?? "—"
            color = row.winner == .project ? .labelColor : .secondaryLabelColor
        }
        let label = projectLabel(value, size: 11, color: color, monospaced: true)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = value
        let cell = NSTableCellView()
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        panel.settingsSearchText = searchField.stringValue
        refresh(model: model)
    }

    @objc private func targetChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        panel.selectedTargetID = TargetID(rawValue: raw)
    }

    @objc private func customizedOnlyChanged(_ sender: NSButton) {
        panel.settingsCustomizedOnly = sender.state == .on
    }

    private var selectedModule: ProjectModule? {
        if let targetID = panel.selectedTargetID,
           let module = model.modules.first(where: { $0.target(for: targetID) != nil }) {
            return module
        }
        return model.modules.first
    }

    private func buildRows() -> [Row] {
        guard let module = selectedModule else { return [] }
        let configName = panel.selectedConfigurationName ?? module.configurationNames.first ?? ""
        let projectConfig = module.configurations.first { $0.name == configName && $0.scope == .project }
        let targetConfig = module.configurations.first { config in
            guard let targetID = panel.selectedTargetID,
                  case let .target(id) = config.scope else { return false }
            return id == targetID && config.name == configName
        }
        let keys = Set(projectConfig?.rawSettings.keys ?? [:].keys)
            .union(targetConfig?.rawSettings.keys ?? [:].keys)
        let filter = panel.settingsSearchText.lowercased()
        return keys.sorted().compactMap { key in
            guard filter.isEmpty || key.lowercased().contains(filter) else { return nil }
            let projectValue = projectConfig?.rawSettings[key]
            let targetValue = targetConfig?.rawSettings[key]
            if panel.settingsCustomizedOnly && targetValue == nil && projectValue == nil { return nil }
            let winner: Row.Winner = targetValue != nil ? .target : (projectValue != nil ? .project : .none)
            return Row(key: key, effective: targetValue ?? projectValue ?? "", target: targetValue, project: projectValue, winner: winner)
        }
    }
}

@MainActor
private final class ProjectSchemesNativeViewController: NSViewController, ProjectTabController,
    NSTableViewDataSource, NSTableViewDelegate
{
    private struct Entry {
        let module: ProjectModule
        let scheme: SchemeSummary
    }

    private let panel: ProjectPanel
    private var model: ProjectModel
    private var entries: [Entry] = []
    private let tableView = NSTableView()
    private let detailContainer = NSView()
    var viewController: NSViewController { self }

    init(panel: ProjectPanel, model: ProjectModel) {
        self.panel = panel
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project.schemes"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        let list = NSScrollView()
        list.documentView = tableView
        list.hasVerticalScroller = true
        list.drawsBackground = true
        list.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.4)
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(list)
        split.addArrangedSubview(detailContainer)
        list.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        detailContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        view = split
        refresh(model: model)
    }

    func refresh(model: ProjectModel) {
        self.model = model
        entries = model.modules.flatMap { module in module.schemes.map { Entry(module: module, scheme: $0) } }
        tableView.reloadData()
        if let selected = panel.selectedSchemeName,
           let index = entries.firstIndex(where: { $0.scheme.name == selected }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        refreshDetail()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let selected = panel.selectedSchemeName == entry.scheme.name
        let cell = ProjectTableCellView()
        cell.wantsLayer = true
        cell.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor : NSColor.clear.cgColor
        let scope = entry.scheme.isShared
            ? String(localized: "projectSchemes.badge.shared", defaultValue: "shared")
            : String(localized: "projectSchemes.badge.personal", defaultValue: "personal")
        let titleRow = NSStackView(views: [projectLabel(entry.scheme.name, size: 12, weight: .semibold), projectBadge(scope, color: entry.scheme.isShared ? .controlAccentColor : .systemOrange), projectFlexibleSpacer()])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        var summaries: [String] = []
        if !entry.scheme.runTargetIDs.isEmpty {
            summaries.append(String.localizedStringWithFormat(
                String(localized: "projectSchemes.row.runFormat", defaultValue: "run: %@"),
                targetNames(entry.scheme.runTargetIDs, module: entry.module)
            ))
        }
        if !entry.scheme.testTargetIDs.isEmpty {
            summaries.append(String.localizedStringWithFormat(
                String(localized: "projectSchemes.row.testFormat", defaultValue: "test: %d"),
                entry.scheme.testTargetIDs.count
            ))
        }
        let content = NSStackView(views: [titleRow, projectLabel(summaries.joined(separator: " · "), size: 10, color: .secondaryLabelColor)])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 2
        content.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        cell.install(content)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = tableView.selectedRow
        guard entries.indices.contains(index) else { return }
        panel.selectedSchemeName = entries[index].scheme.name
        tableView.reloadData()
        refreshDetail()
    }

    private func refreshDetail() {
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        let detail: NSView
        if let entry = entries.first(where: { $0.scheme.name == panel.selectedSchemeName }) {
            detail = schemeDetail(entry)
        } else {
            detail = projectEmptyDetail(
                systemImage: "play.rectangle",
                title: String(localized: "projectSchemes.empty.title", defaultValue: "Select a scheme"),
                hint: String(localized: "projectSchemes.empty.hint", defaultValue: "Pick a scheme on the left to inspect its run / test / profile / archive targets and launch settings.")
            )
        }
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detail)
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detail.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detail.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
    }

    private func schemeDetail(_ entry: Entry) -> NSView {
        let stack = projectDetailStack()
        stack.addArrangedSubview(projectTitleRow(entry.scheme.name, symbol: "play.rectangle.fill"))
        stack.addArrangedSubview(projectDetailRow(
            String(localized: "projectSchemes.detail.visibility", defaultValue: "Visibility"),
            value: entry.scheme.isShared
                ? String(localized: "projectSchemes.detail.visibilityShared", defaultValue: "Shared")
                : String(localized: "projectSchemes.detail.visibilityPersonal", defaultValue: "Personal (current user)")
        ))
        addTargets(entry.scheme.runTargetIDs, label: String(localized: "projectSchemes.detail.runTarget", defaultValue: "Run target"), entry: entry, to: stack)
        addTargets(entry.scheme.testTargetIDs, label: String(localized: "projectSchemes.detail.testTargets", defaultValue: "Test targets"), entry: entry, to: stack)
        if let target = entry.scheme.profileTargetID {
            addTargets([target], label: String(localized: "projectSchemes.detail.profileTarget", defaultValue: "Profile target"), entry: entry, to: stack)
        }
        if let target = entry.scheme.archiveTargetID {
            addTargets([target], label: String(localized: "projectSchemes.detail.archiveTarget", defaultValue: "Archive target"), entry: entry, to: stack)
        }
        if !entry.scheme.launchArguments.isEmpty {
            stack.addArrangedSubview(projectSectionLabel(String(localized: "projectSchemes.detail.launchArguments", defaultValue: "Launch arguments")))
            for argument in entry.scheme.launchArguments {
                stack.addArrangedSubview(projectLabel(argument, size: 11, monospaced: true))
            }
        }
        if !entry.scheme.environmentVariables.isEmpty {
            stack.addArrangedSubview(projectSectionLabel(String(localized: "projectSchemes.detail.environment", defaultValue: "Environment")))
            for pair in entry.scheme.environmentVariables.sorted(by: { $0.key < $1.key }) {
                stack.addArrangedSubview(projectLabel("\(pair.key) = \(pair.value)", size: 11, monospaced: true))
            }
        }
        return projectVerticalScroll(stack)
    }

    private func addTargets(_ ids: [TargetID], label: String, entry: Entry, to stack: NSStackView) {
        guard !ids.isEmpty else { return }
        stack.addArrangedSubview(projectDetailRow(label, value: targetNames(ids, module: entry.module)))
    }

    private func targetNames(_ ids: [TargetID], module: ProjectModule) -> String {
        ids.map { module.target(for: $0)?.displayName ?? String($0.rawValue.prefix(8)) }.joined(separator: ", ")
    }
}

@MainActor
private final class ProjectTableCellView: NSTableCellView {
    func install(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

@MainActor
private func projectFlexibleSpacer() -> NSView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return spacer
}

@MainActor
private func projectSeparator() -> NSBox {
    let separator = NSBox()
    separator.boxType = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false
    separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return separator
}

@MainActor
private func projectLabel(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor,
    monospaced: Bool = false
) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = monospaced
        ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        : NSFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    return label
}

@MainActor
private func projectSymbol(_ name: String, color: NSColor = .labelColor) -> NSImageView {
    let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
    view.contentTintColor = color
    view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
    view.setContentHuggingPriority(.required, for: .horizontal)
    return view
}

@MainActor
private func projectBadge(_ text: String, color: NSColor) -> NSView {
    let label = projectLabel(text, size: 9, weight: .medium, color: color)
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
    container.layer?.cornerRadius = 3
    label.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
        label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
        label.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
        label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
    ])
    return container
}

@MainActor
private func projectDetailStack() -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    return stack
}

@MainActor
private func projectTitleRow(_ title: String, symbol: String) -> NSView {
    let stack = NSStackView(views: [projectSymbol(symbol, color: .controlAccentColor), projectLabel(title, size: 14, weight: .semibold), projectFlexibleSpacer()])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 8
    return stack
}

@MainActor
private func projectSectionLabel(_ text: String) -> NSTextField {
    projectLabel(text, size: 11, weight: .semibold, color: .secondaryLabelColor)
}

@MainActor
private func projectDetailRow(_ label: String, value: String, monospaced: Bool = false) -> NSView {
    let labelView = projectLabel(label, size: 11, weight: .semibold, color: .secondaryLabelColor)
    labelView.widthAnchor.constraint(equalToConstant: 110).isActive = true
    let valueView = projectLabel(value, size: 11, monospaced: monospaced)
    valueView.maximumNumberOfLines = 0
    valueView.lineBreakMode = .byWordWrapping
    valueView.toolTip = value
    let stack = NSStackView(views: [labelView, valueView])
    stack.orientation = .horizontal
    stack.alignment = .top
    stack.spacing = 8
    return stack
}

@MainActor
private func projectVerticalScroll(_ document: NSView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    let container = NSView()
    document.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(document)
    NSLayoutConstraint.activate([
        document.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        document.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        document.topAnchor.constraint(equalTo: container.topAnchor),
        document.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
    ])
    scroll.documentView = container
    return scroll
}

@MainActor
private func projectEmptyDetail(systemImage: String, title: String, hint: String) -> NSView {
    let icon = projectSymbol(systemImage, color: .tertiaryLabelColor)
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
    let hintLabel = projectLabel(hint, size: 11, color: .secondaryLabelColor)
    hintLabel.maximumNumberOfLines = 0
    hintLabel.lineBreakMode = .byWordWrapping
    hintLabel.alignment = .center
    let content = NSStackView(views: [icon, projectLabel(title, size: 13, weight: .semibold), hintLabel])
    content.orientation = .vertical
    content.alignment = .centerX
    content.spacing = 6
    let root = NSView()
    content.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(content)
    NSLayoutConstraint.activate([
        content.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        content.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        content.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
        content.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
    ])
    return root
}

@MainActor
private func targetGlyph(_ productType: TargetProductType) -> String {
    switch productType {
    case .application: "app.fill"
    case .framework, .dynamicLibrary, .staticLibrary, .xcFramework: "shippingbox"
    case .bundle: "shippingbox.fill"
    case .unitTest, .uiTest: "testtube.2"
    case .commandLineTool: "terminal"
    case .appExtension: "puzzlepiece.extension"
    case .watchApp, .watchExtension: "applewatch"
    case .other: "questionmark.square"
    }
}
