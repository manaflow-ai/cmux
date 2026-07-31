import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation

enum VaultHistoryRowAction: Equatable {
    case resumeSession(SessionEntry)
    case reopenClosedItem(UUID)
    case activateWorkspace(UUID)
    case activateTerminal(workspaceId: UUID, terminalId: UUID)

    var label: String {
        switch self {
        case .resumeSession:
            return String(localized: "sessionIndex.row.resume", defaultValue: "Resume in New Tab")
        case .reopenClosedItem:
            return String(localized: "vaultHistory.action.reopen", defaultValue: "Reopen")
        case .activateWorkspace:
            return String(
                localized: "vaultHistory.action.goToWorkspace",
                defaultValue: "Go to Workspace"
            )
        case .activateTerminal:
            return String(
                localized: "vaultHistory.action.goToTerminal",
                defaultValue: "Go to Terminal"
            )
        }
    }

    var symbolName: String {
        switch self {
        case .resumeSession: return "play.fill"
        case .reopenClosedItem: return "arrow.uturn.backward"
        case .activateWorkspace, .activateTerminal: return "arrow.right"
        }
    }
}

struct VaultHistoryRowActions {
    let onResume: ((SessionEntry) -> Void)?
    let onReopenClosedItem: ((UUID) -> Bool)?
    let onActivateWorkspace: ((UUID) -> Bool)?
    let onActivateTerminal: ((UUID, UUID) -> Bool)?

    init(
        onResume: ((SessionEntry) -> Void)?,
        onReopenClosedItem: ((UUID) -> Bool)?,
        onActivateWorkspace: ((UUID) -> Bool)? = nil,
        onActivateTerminal: ((UUID, UUID) -> Bool)? = nil
    ) {
        self.onResume = onResume
        self.onReopenClosedItem = onReopenClosedItem
        self.onActivateWorkspace = onActivateWorkspace
        self.onActivateTerminal = onActivateTerminal
    }

    var canResume: Bool { onResume != nil }
    var canReopen: Bool { onReopenClosedItem != nil }
    var canActivateWorkspace: Bool { onActivateWorkspace != nil }
    var canActivateTerminal: Bool { onActivateTerminal != nil }

    func perform(_ action: VaultHistoryRowAction) {
        switch action {
        case .resumeSession(let entry): onResume?(entry)
        case .reopenClosedItem(let id): _ = onReopenClosedItem?(id)
        case .activateWorkspace(let id): _ = onActivateWorkspace?(id)
        case .activateTerminal(let workspaceId, let terminalId):
            _ = onActivateTerminal?(workspaceId, terminalId)
        }
    }
}

/// Recycled pure-AppKit History event row.
@MainActor
final class VaultHistoryTableEventCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("VaultHistoryTableEventCellView")

    private let iconView = CmuxResolvedIconImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private lazy var textStack = NSStackView(views: [titleLabel, subtitleLabel])
    private var iconLeadingConstraint: NSLayoutConstraint!
    private var actionButtonWidthConstraint: NSLayoutConstraint!
    private var representedEventItem: VaultHistoryTableRow.EventItem?
    private var representedTopologyItem: VaultHistoryTableRow.TopologyItem?
    private var representedAction: VaultHistoryRowAction?
    private var representedFontPercent = GlobalFontMagnification.defaultPercent
    private var onPerformAction: ((VaultHistoryRowAction) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true
        layer?.masksToBounds = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        for label in [titleLabel, subtitleLabel, timeLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
            label.cell?.truncatesLastVisibleLine = true
            label.cell?.usesSingleLineMode = true
            label.cell?.wraps = false
            label.setAccessibilityElement(false)
        }
        titleLabel.textColor = NSColor.labelColor.withAlphaComponent(0.85)
        subtitleLabel.textColor = .secondaryLabelColor
        timeLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        timeLabel.alignment = .right
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.distribution = .fill
        textStack.spacing = 1
        addSubview(textStack)

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.isBordered = false
        actionButton.imagePosition = .imageOnly
        actionButton.focusRingType = .none
        actionButton.target = self
        actionButton.action = #selector(performRepresentedAction(_:))
        addSubview(actionButton)
        actionButtonWidthConstraint = actionButton.widthAnchor.constraint(equalToConstant: 0)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeLabel)
        iconLeadingConstraint = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        NSLayoutConstraint.activate([
            iconLeadingConstraint,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButtonWidthConstraint,
            actionButton.heightAnchor.constraint(equalToConstant: 18),

            timeLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -4),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 4),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedEventItem = nil
        representedTopologyItem = nil
        representedAction = nil
        onPerformAction = nil
        iconView.apply(nil)
    }

    func configure(
        event: VaultHistoryEvent,
        action: VaultHistoryRowAction?,
        agent: SessionAgent?,
        globalFontMagnificationPercent: Int,
        onPerformAction: @escaping (VaultHistoryRowAction) -> Void
    ) {
        configure(
            eventItem: VaultHistoryTableRow.EventItem(
                event: event,
                action: action,
                agent: agent
            ),
            globalFontMagnificationPercent: globalFontMagnificationPercent,
            onPerformAction: onPerformAction
        )
    }

    func configure(
        eventItem: VaultHistoryTableRow.EventItem,
        globalFontMagnificationPercent: Int,
        onPerformAction: @escaping (VaultHistoryRowAction) -> Void
    ) {
        self.onPerformAction = onPerformAction
        representedTopologyItem = nil
        guard representedEventItem != eventItem
                || representedFontPercent != globalFontMagnificationPercent else {
            updateRelativeTimestamp(eventItem.timestamp)
            return
        }
        representedEventItem = eventItem
        representedAction = eventItem.action
        representedFontPercent = globalFontMagnificationPercent
        iconLeadingConstraint.constant = 10

        titleLabel.stringValue = eventItem.title
        subtitleLabel.stringValue = eventItem.subtitle
        titleLabel.toolTip = eventItem.titleTooltip.isEmpty ? nil : eventItem.titleTooltip
        subtitleLabel.toolTip = eventItem.subtitle.isEmpty ? nil : eventItem.subtitle
        titleLabel.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(11.5, percent: globalFontMagnificationPercent)
        )
        subtitleLabel.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(10, percent: globalFontMagnificationPercent)
        )
        timeLabel.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(10, percent: globalFontMagnificationPercent)
        )
        configureIcon(eventItem.icon)
        configureAction(eventItem.action)
        updateRelativeTimestamp(eventItem.timestamp)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(eventItem.accessibilityIdentifier)
        setAccessibilityLabel([
            titleLabel.stringValue,
            subtitleLabel.stringValue,
            timeLabel.stringValue,
        ].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    func configure(
        topologyItem: VaultHistoryTableRow.TopologyItem,
        globalFontMagnificationPercent: Int,
        onPerformAction: @escaping (VaultHistoryRowAction) -> Void
    ) {
        self.onPerformAction = onPerformAction
        representedEventItem = nil
        guard representedTopologyItem != topologyItem
                || representedFontPercent != globalFontMagnificationPercent else {
            updateRelativeTimestamp(topologyItem.timestamp)
            return
        }
        representedTopologyItem = topologyItem
        representedAction = topologyItem.action
        representedFontPercent = globalFontMagnificationPercent
        iconLeadingConstraint.constant = 10 + CGFloat(max(0, topologyItem.indentationLevel)) * 16

        titleLabel.stringValue = topologyItem.title
        subtitleLabel.stringValue = topologyItem.subtitle
        titleLabel.toolTip = topologyItem.title
        subtitleLabel.toolTip = subtitleLabel.stringValue
        titleLabel.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(11.5, percent: globalFontMagnificationPercent)
        )
        subtitleLabel.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(10, percent: globalFontMagnificationPercent)
        )
        timeLabel.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(10, percent: globalFontMagnificationPercent)
        )
        configureIcon(topologyItem.icon)
        configureAction(topologyItem.action)
        updateRelativeTimestamp(topologyItem.timestamp)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(topologyItem.accessibilityIdentifier)
        setAccessibilityLabel([
            titleLabel.stringValue,
            subtitleLabel.stringValue,
            timeLabel.stringValue,
        ].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private func configureIcon(_ icon: VaultHistoryTableRow.Icon) {
        switch icon {
        case .agent(let agent):
            configureAgentIcon(agent, description: agent.displayName)
        case .system(let name, let style):
            iconView.apply(CmuxResolvedIconRequest(
                source: .systemSymbol(name: name, accessibilityDescription: nil),
                size: NSSize(width: 14, height: 14),
                tintColor: style == .active ? .systemGreen : .secondaryLabelColor
            ))
        }
    }

    private func configureAgentIcon(_ agent: SessionAgent, description: String) {
        let source: CmuxResolvedIconSource
        if let assetName = agent.assetName {
            source = .asset(name: assetName, bundle: .main)
        } else {
            source = .systemSymbol(
                name: agent.systemImageName ?? "person.crop.circle",
                accessibilityDescription: description
            )
        }
        iconView.apply(CmuxResolvedIconRequest(
            source: source,
            size: NSSize(width: 14, height: 14),
            tintColor: agent.assetName == nil ? .secondaryLabelColor : nil
        ))
    }

    private func configureAction(_ action: VaultHistoryRowAction?) {
        representedAction = action
        guard let action else {
            actionButton.isHidden = true
            actionButtonWidthConstraint.constant = 0
            actionButton.image = nil
            actionButton.toolTip = nil
            actionButton.setAccessibilityLabel(nil)
            return
        }
        actionButton.isHidden = false
        actionButtonWidthConstraint.constant = 18
        actionButton.image = Self.actionButtonImage(symbolName: action.symbolName)
        actionButton.contentTintColor = .secondaryLabelColor
        actionButton.toolTip = action.label
        actionButton.setAccessibilityLabel(action.label)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let action = representedAction else { return nil }
        let contextMenu = NSMenu()
        let item = NSMenuItem(
            title: action.label,
            action: #selector(performRepresentedAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil)
        contextMenu.addItem(item)
        return contextMenu
    }

    private func updateRelativeTimestamp(_ timestamp: Date?) {
        guard let timestamp else {
            timeLabel.stringValue = ""
            timeLabel.toolTip = nil
            timeLabel.isHidden = true
            return
        }
        timeLabel.isHidden = false
        timeLabel.stringValue = Self.relativeFormatter.localizedString(
            for: timestamp,
            relativeTo: Date()
        )
        timeLabel.toolTip = timestamp.formatted(date: .abbreviated, time: .shortened)
    }

    @objc private func performRepresentedAction(_ sender: Any?) {
        guard let representedAction else { return }
        onPerformAction?(representedAction)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static var actionButtonImages: [String: NSImage] = [:]

    private static func actionButtonImage(symbolName: String) -> NSImage? {
        if let image = actionButtonImages[symbolName] { return image }
        guard let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium)) else {
            return nil
        }
        actionButtonImages[symbolName] = image
        return image
    }

    static func displayTitle(for event: VaultHistoryEvent) -> String {
        VaultHistoryTableRow.EventItem(event: event, action: nil, agent: nil).title
    }

    static func displaySubtitle(for event: VaultHistoryEvent) -> String {
        VaultHistoryTableRow.EventItem(event: event, action: nil, agent: nil).subtitle
    }
}

enum VaultHistoryDisplayText {
    static let rowMaximumLength = 240
    static let tooltipMaximumLength = 480

    static func singleLine(
        _ value: String,
        maximumLength: Int = rowMaximumLength
    ) -> String {
        guard maximumLength > 0 else { return "" }
        var result = ""
        result.reserveCapacity(maximumLength + 1)
        var visibleLength = 0
        var inspectedLength = 0
        var hasPendingSpace = false
        let inspectionLimit = max(4_096, maximumLength * 16)

        for scalar in value.unicodeScalars {
            inspectedLength += 1
            if inspectedLength > inspectionLimit {
                return result + "…"
            }
            if scalar.properties.isWhitespace {
                hasPendingSpace = !result.isEmpty
                continue
            }
            if hasPendingSpace {
                guard visibleLength < maximumLength else { return result + "…" }
                result.append(" ")
                visibleLength += 1
                hasPendingSpace = false
            }
            guard visibleLength < maximumLength else { return result + "…" }
            result.unicodeScalars.append(scalar)
            visibleLength += 1
        }
        return result
    }
}
