import AppKit
import CmuxFoundation
import CmuxSettings
import Observation

@MainActor
final class AllShortcutsPopoverController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class RowItem: NSObject {
        let id: String
        let label: String
        let keys: String
        let isUnassigned: Bool

        init(id: String, label: String, keys: String, isUnassigned: Bool) {
            self.id = id
            self.label = label
            self.keys = keys
            self.isUnassigned = isUnassigned
        }
    }

    private final class SectionItem: NSObject {
        let id: String
        let title: String
        let rows: [RowItem]

        init(id: String, title: String, rows: [RowItem]) {
            self.id = id
            self.title = title
            self.rows = rows
        }
    }

    private let outlineView = NSOutlineView()
    private var sections: [SectionItem] = []
    private var observationGeneration: UInt64 = 0
    private var globalFontObserver: GlobalFontMagnificationChangeObserver?

    override func loadView() {
        let root = NSView()
        root.setAccessibilityIdentifier("AllShortcutsPopover")
        view = root

        let title = NSTextField(
            labelWithString: String(
                localized: "settings.section.keyboardShortcuts",
                defaultValue: "Keyboard Shortcuts"
            )
        )
        title.font = GlobalFontMagnification.systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Shortcut"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .none
        outlineView.intercellSpacing = .zero
        outlineView.indentationPerLevel = 0
        outlineView.floatsGroupRows = true
        outlineView.dataSource = self
        outlineView.delegate = self

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = outlineView

        root.addSubview(title)
        root.addSubview(separator)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        preferredContentSize = NSSize(width: 320, height: 440)
        reloadSnapshot()
        observeShortcutChanges()
        globalFontObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.reloadSnapshot()
        }
    }

    private func observeShortcutChanges() {
        observationGeneration &+= 1
        let generation = observationGeneration
        withObservationTracking {
            _ = KeyboardShortcutSettingsObserver.shared.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.reloadSnapshot()
                self.observeShortcutChanges()
            }
        }
    }

    private func reloadSnapshot() {
        sections = Self.makeSections()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    private static func makeSections() -> [SectionItem] {
        var rowsByGroup: [ShortcutAction.Group: [RowItem]] = [:]
        var otherRows: [RowItem] = []

        for action in KeyboardShortcutSettings.settingsVisibleActions {
            let stored = KeyboardShortcutSettings.shortcut(for: action)
            let isUnassigned = stored.isUnbound
            let row = RowItem(
                id: action.rawValue,
                label: action.label,
                keys: isUnassigned
                    ? String(localized: "shortcutDiscovery.unassigned", defaultValue: "Unassigned")
                    : action.displayedShortcutString(for: stored),
                isUnassigned: isUnassigned
            )
            if let group = ShortcutAction(rawValue: action.rawValue)?.group {
                rowsByGroup[group, default: []].append(row)
            } else {
                otherRows.append(row)
            }
        }

        var result = ShortcutAction.Group.allCases.compactMap { group -> SectionItem? in
            guard let rows = rowsByGroup[group], !rows.isEmpty else { return nil }
            return SectionItem(id: group.rawValue, title: localizedTitle(for: group), rows: rows)
        }
        if !otherRows.isEmpty {
            result.append(
                SectionItem(
                    id: "other",
                    title: String(localized: "shortcutDiscovery.section.other", defaultValue: "Other"),
                    rows: otherRows
                )
            )
        }
        return result
    }

    private static func localizedTitle(for group: ShortcutAction.Group) -> String {
        switch group {
        case .app:
            String(localized: "shortcutDiscovery.section.app", defaultValue: "App")
        case .workspace:
            String(localized: "shortcutDiscovery.section.workspace", defaultValue: "Workspace")
        case .navigation:
            String(localized: "shortcutDiscovery.section.navigation", defaultValue: "Navigation")
        case .panes:
            String(localized: "shortcutDiscovery.section.panes", defaultValue: "Panes")
        case .browser:
            String(localized: "shortcutDiscovery.section.browser", defaultValue: "Browser & Find")
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let section = item as? SectionItem {
            return section.rows.count
        }
        return sections.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let section = item as? SectionItem {
            return section.rows[index]
        }
        return sections[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SectionItem
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SectionItem
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is SectionItem ? 28 : 30
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        if let section = item as? SectionItem {
            let identifier = NSUserInterfaceItemIdentifier("ShortcutSection")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self)
                as? ShortcutDiscoverySectionCellView ?? ShortcutDiscoverySectionCellView()
            cell.identifier = identifier
            cell.update(title: section.title)
            return cell
        }
        guard let row = item as? RowItem else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ShortcutRow")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self)
            as? ShortcutDiscoveryRowCellView ?? ShortcutDiscoveryRowCellView()
        cell.identifier = identifier
        cell.update(label: row.label, keys: row.keys, isUnassigned: row.isUnassigned)
        return cell
    }
}

@MainActor
private final class ShortcutDiscoverySectionCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String) {
        titleLabel.stringValue = title
        titleLabel.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
    }
}

@MainActor
private final class ShortcutDiscoveryRowCellView: NSTableCellView {
    private let actionLabel = NSTextField(labelWithString: "")
    private let keyLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        actionLabel.lineBreakMode = .byTruncatingTail
        actionLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.alignment = .center
        keyLabel.wantsLayer = true
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(actionLabel)
        addSubview(keyLabel)
        NSLayoutConstraint.activate([
            actionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            actionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionLabel.trailingAnchor.constraint(lessThanOrEqualTo: keyLabel.leadingAnchor, constant: -8),
            keyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            keyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            keyLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            keyLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateKeyBackground()
    }

    func update(label: String, keys: String, isUnassigned: Bool) {
        actionLabel.stringValue = label
        actionLabel.font = GlobalFontMagnification.systemFont(ofSize: 12)
        keyLabel.stringValue = "  \(keys)  "
        keyLabel.font = roundedFont(size: isUnassigned ? 11 : 12, weight: isUnassigned ? .regular : .medium)
        keyLabel.textColor = isUnassigned ? .tertiaryLabelColor : .labelColor
        keyLabel.tag = isUnassigned ? 1 : 0
        updateKeyBackground()
    }

    private func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let font = GlobalFontMagnification.systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private func updateKeyBackground() {
        let isUnassigned = keyLabel.tag == 1
        keyLabel.layer?.cornerRadius = isUnassigned ? 0 : 5
        keyLabel.layer?.borderWidth = isUnassigned ? 0 : 1
        keyLabel.layer?.backgroundColor = isUnassigned
            ? NSColor.clear.cgColor
            : NSColor.labelColor.withAlphaComponent(0.08).cgColor
        keyLabel.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    }
}
