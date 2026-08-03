import AppKit
import CmuxFoundation
import Observation

enum InternalFlagsPresenter {
    @MainActor
    static func present() {
        InternalFlagsWindowController.shared.show()
    }
}

@MainActor
private final class InternalFlagsWindowController: NSWindowController {
    static let shared = InternalFlagsWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "featureFlags.window.title", defaultValue: "Feature Flags")
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 760, height: 420)
        window.contentView = InternalFlagsView(flags: CmuxFeatureFlags.shared)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        if window?.isVisible != true {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class InternalFlagsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Item {
#if DEBUG
        case devBuildBanner
#endif
        case flag(InternalFlagRowSnapshot)
    }

    private let flags: CmuxFeatureFlags
    private let tableView = NSTableView()
    private let clearButton = NSButton()
    private var items: [Item] = []

    init(flags: CmuxFeatureFlags) {
        self.flags = flags
        super.init(frame: .zero)
        setupView()
        refreshFromModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let heading = NSTextField(labelWithString: String(
            localized: "featureFlags.window.heading",
            defaultValue: "Feature Flags"
        ))
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: String(
            localized: "featureFlags.window.subtitle",
            defaultValue: "Inspect PostHog flag state and local overrides for this Mac."
        ))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let header = NSStackView(views: [heading, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 16, right: 24)

        configureTable()
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let footerNote = NSTextField(wrappingLabelWithString: String(
            localized: "featureFlags.footer.note",
            defaultValue: "Local overrides apply only when no remote value is available."
        ))
        footerNote.font = .systemFont(ofSize: 11)
        footerNote.textColor = .secondaryLabelColor
        clearButton.title = String(localized: "featureFlags.clearAll", defaultValue: "Clear all overrides")
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearAllOverrides)
        let footer = NSStackView(views: [footerNote, NSView(), clearButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 16
        footer.edgeInsets = NSEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        footer.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerSeparator = NSBox()
        headerSeparator.boxType = .separator
        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        let root = NSStackView(views: [header, headerSeparator, scrollView, footerSeparator, footer])
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 760),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.selectionHighlightStyle = .none
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.intercellSpacing = NSSize(width: 16, height: 0)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        addColumn("flag", title: String(localized: "featureFlags.column.flag", defaultValue: "Flag"), width: 440, minimum: 300)
        addColumn("current", title: String(localized: "featureFlags.column.current", defaultValue: "Current"), width: 96)
        addColumn("source", title: String(localized: "featureFlags.column.source", defaultValue: "Source"), width: 96)
        addColumn("override", title: String(localized: "featureFlags.column.override", defaultValue: "Override"), width: 250)
    }

    private func addColumn(_ identifier: String, title: String, width: CGFloat, minimum: CGFloat? = nil) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = minimum ?? width
        column.maxWidth = identifier == "flag" ? .greatestFiniteMagnitude : width
        column.resizingMask = identifier == "flag" ? .autoresizingMask : []
        tableView.addTableColumn(column)
    }

    private func refreshFromModel() {
        withObservationTracking {
            var next: [Item] = []
#if DEBUG
            next.append(.devBuildBanner)
#endif
            next.append(contentsOf: CmuxFeatureFlags.allFlags.map { definition in
                .flag(InternalFlagRowSnapshot(
                    definition: definition,
                    resolution: flags.resolution(for: definition),
                    overrideValue: flags.overrideValue(for: definition)
                ))
            })
            items = next
            clearButton.isEnabled = CmuxFeatureFlags.allFlags.contains {
                flags.overrideValue(for: $0) != nil
            }
            tableView.reloadData()
        } onChange: { [weak self] in
            Task { @MainActor in self?.refreshFromModel() }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        82
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row), let tableColumn else { return nil }
        let identifier = tableColumn.identifier.rawValue
        switch items[row] {
#if DEBUG
        case .devBuildBanner:
            return debugBannerCell(for: identifier)
#endif
        case .flag(let snapshot):
            return flagCell(for: identifier, snapshot: snapshot)
        }
    }

    private func flagCell(for column: String, snapshot: InternalFlagRowSnapshot) -> NSView {
        switch column {
        case "flag":
            return descriptionCell(
                title: snapshot.definition.title,
                key: snapshot.definition.key,
                detail: snapshot.definition.flagDescription
            )
        case "current":
            let label = centeredLabel(snapshot.resolution.effectiveValue
                ? String(localized: "featureFlags.value.on", defaultValue: "On")
                : String(localized: "featureFlags.value.off", defaultValue: "Off"))
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = snapshot.resolution.effectiveValue ? .systemGreen : .secondaryLabelColor
            return label
        case "source":
            return centeredLabel(snapshot.sourceTitle)
        default:
            let control = InternalFlagOverrideControl(snapshot: snapshot)
            control.target = self
            control.action = #selector(flagOverrideChanged(_:))
            return centered(control)
        }
    }

#if DEBUG
    private func debugBannerCell(for column: String) -> NSView {
        switch column {
        case "flag":
            return descriptionCell(
                title: String(localized: "debug.devBuildBanner.show", defaultValue: "Show Dev Build Banner"),
                key: DevBuildBannerDebugSettings.sidebarBannerVisibleKey,
                detail: String(
                    localized: "debug.devBuildBanner.description",
                    defaultValue: "Controls the red debug-build label below the sidebar footer."
                )
            )
        case "current":
            let enabled = DevBuildBannerDebugSettings().showSidebarBanner
            return centeredLabel(enabled
                ? String(localized: "featureFlags.value.on", defaultValue: "On")
                : String(localized: "featureFlags.value.off", defaultValue: "Off"))
        case "source":
            return centeredLabel(String(localized: "featureFlags.source.local", defaultValue: "Local"))
        default:
            let control = NSSegmentedControl(
                labels: [
                    String(localized: "featureFlags.override.on", defaultValue: "On"),
                    String(localized: "featureFlags.override.off", defaultValue: "Off"),
                ],
                trackingMode: .selectOne,
                target: self,
                action: #selector(devBannerChanged(_:))
            )
            control.selectedSegment = DevBuildBannerDebugSettings().showSidebarBanner ? 0 : 1
            control.identifier = NSUserInterfaceItemIdentifier("InternalFlagsDevBuildBannerPicker")
            control.setAccessibilityLabel(String(localized: "featureFlags.override.pickerLabel", defaultValue: "Override"))
            return centered(control)
        }
    }
#endif

    private func descriptionCell(title: String, key: String, detail: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.lineBreakMode = .byTruncatingTail
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        let stack = NSStackView(views: [titleLabel, keyLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 0)
        return stack
    }

    private func centeredLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        return label
    }

    private func centered(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    @objc private func flagOverrideChanged(_ sender: InternalFlagOverrideControl) {
        flags.setOverride(sender.choice.overrideValue, for: sender.definition)
    }

#if DEBUG
    @objc private func devBannerChanged(_ sender: NSSegmentedControl) {
        UserDefaults.standard.set(sender.selectedSegment == 0, forKey: DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
        tableView.reloadData()
    }
#endif

    @objc private func clearAllOverrides() {
        flags.clearAllOverrides()
    }
}

private struct InternalFlagRowSnapshot: Equatable {
    let definition: CmuxFeatureFlagDefinition
    let resolution: CmuxFeatureFlagResolution
    let overrideValue: Bool?

    var sourceTitle: String {
        switch resolution.source {
        case .remote:
            return String(localized: "featureFlags.source.remote", defaultValue: "Remote")
        case .override:
            return String(localized: "featureFlags.source.override", defaultValue: "Override")
        case .default:
            return String(localized: "featureFlags.source.default", defaultValue: "Default")
        }
    }

    var overrideChoice: InternalFlagOverrideChoice {
        switch overrideValue {
        case .some(true): return .on
        case .some(false): return .off
        case .none: return .noOverride
        }
    }
}

@MainActor
private final class InternalFlagOverrideControl: NSSegmentedControl {
    let definition: CmuxFeatureFlagDefinition

    init(snapshot: InternalFlagRowSnapshot) {
        definition = snapshot.definition
        super.init(frame: .zero)
        segmentCount = InternalFlagOverrideChoice.allCases.count
        trackingMode = .selectOne
        for choice in InternalFlagOverrideChoice.allCases {
            setLabel(choice.title, forSegment: choice.rawValue)
        }
        selectedSegment = snapshot.overrideChoice.rawValue
        isEnabled = snapshot.resolution.source != .remote
        setAccessibilityLabel(String(localized: "featureFlags.override.pickerLabel", defaultValue: "Override"))
        if snapshot.resolution.source == .remote {
            toolTip = String(
                localized: "featureFlags.override.remoteControlledNote",
                defaultValue: "Controlled remotely; local override inactive."
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var choice: InternalFlagOverrideChoice {
        InternalFlagOverrideChoice(rawValue: selectedSegment) ?? .noOverride
    }
}

private enum InternalFlagOverrideChoice: Int, CaseIterable {
    case on
    case off
    case noOverride

    var title: String {
        switch self {
        case .on:
            return String(localized: "featureFlags.override.on", defaultValue: "On")
        case .off:
            return String(localized: "featureFlags.override.off", defaultValue: "Off")
        case .noOverride:
            return String(localized: "featureFlags.override.none", defaultValue: "No override")
        }
    }

    var overrideValue: Bool? {
        switch self {
        case .on: return true
        case .off: return false
        case .noOverride: return nil
        }
    }
}
