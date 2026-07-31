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

    private let hoverBackground = VaultHistoryHitTransparentView()
    private let iconView = CmuxResolvedIconImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private lazy var textStack = NSStackView(views: [titleLabel, subtitleLabel])
    private var iconLeadingConstraint: NSLayoutConstraint!
    private var actionButtonWidthConstraint: NSLayoutConstraint!
    private var representedEvent: VaultHistoryEvent?
    private var representedTopologyItem: VaultHistoryTableRow.TopologyItem?
    private var representedAction: VaultHistoryRowAction?
    private var representedAgent: SessionAgent?
    private var representedFontPercent = GlobalFontMagnification.defaultPercent
    private var onPerformAction: ((VaultHistoryRowAction) -> Void)?
    private var isPointerHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true
        layer?.masksToBounds = true

        hoverBackground.translatesAutoresizingMaskIntoConstraints = false
        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = 4
        hoverBackground.layer?.cornerCurve = .continuous
        addSubview(hoverBackground)

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
            hoverBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            hoverBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            hoverBackground.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hoverBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

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

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
        updateHoverPresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedEvent = nil
        representedTopologyItem = nil
        representedAction = nil
        representedAgent = nil
        onPerformAction = nil
        iconView.apply(nil)
        menu = nil
    }

    func configure(
        event: VaultHistoryEvent,
        action: VaultHistoryRowAction?,
        agent: SessionAgent?,
        globalFontMagnificationPercent: Int,
        onPerformAction: @escaping (VaultHistoryRowAction) -> Void
    ) {
        self.onPerformAction = onPerformAction
        representedTopologyItem = nil
        guard representedEvent != event
                || representedAction != action
                || representedAgent != agent
                || representedFontPercent != globalFontMagnificationPercent else {
            updateRelativeTimestamp(for: event)
            return
        }
        representedEvent = event
        representedAction = action
        representedAgent = agent
        representedFontPercent = globalFontMagnificationPercent
        iconLeadingConstraint.constant = 10

        titleLabel.stringValue = Self.displayTitle(for: event)
        subtitleLabel.stringValue = Self.displaySubtitle(for: event)
        titleLabel.toolTip = VaultHistoryDisplayText.singleLine(event.title)
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
        configureIcon(event: event, agent: agent)
        configureAction(action)
        updateRelativeTimestamp(for: event)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("VaultHistoryEventRow:\(event.id)")
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
        representedEvent = nil
        guard representedTopologyItem != topologyItem
                || representedFontPercent != globalFontMagnificationPercent else {
            updateRelativeTimestamp(topologyItem.timestamp)
            return
        }
        representedTopologyItem = topologyItem
        representedAction = topologyItem.action
        representedFontPercent = globalFontMagnificationPercent
        iconLeadingConstraint.constant = 10 + CGFloat(max(0, topologyItem.indentationLevel)) * 16

        let title = VaultHistoryDisplayText.singleLine(topologyItem.title)
        titleLabel.stringValue = Self.truncated(title, maximumLength: 240)
        subtitleLabel.stringValue = VaultHistoryDisplayText.singleLine(topologyItem.subtitle)
        titleLabel.toolTip = title
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

    override func mouseEntered(with event: NSEvent) {
        isPointerHovering = true
        updateHoverPresentation()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerHovering = false
        updateHoverPresentation()
    }

    private func configureIcon(event: VaultHistoryEvent, agent: SessionAgent?) {
        if event.kind == .sessionActivity, let agent {
            configureAgentIcon(
                agent,
                description: event.subject.agentDisplayName ?? agent.displayName
            )
            return
        }
        iconView.apply(CmuxResolvedIconRequest(
            source: .systemSymbol(name: event.kind.symbolName, accessibilityDescription: event.kind.label),
            size: NSSize(width: 14, height: 14),
            tintColor: .secondaryLabelColor
        ))
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
            menu = nil
            return
        }
        actionButton.isHidden = false
        actionButtonWidthConstraint.constant = 18
        actionButton.image = NSImage(
            systemSymbolName: action.symbolName,
            accessibilityDescription: action.label
        )?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        actionButton.contentTintColor = .secondaryLabelColor
        actionButton.toolTip = action.label
        actionButton.setAccessibilityLabel(action.label)

        let contextMenu = NSMenu()
        let item = NSMenuItem(
            title: action.label,
            action: #selector(performRepresentedAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil)
        contextMenu.addItem(item)
        menu = contextMenu
    }

    private func updateRelativeTimestamp(for event: VaultHistoryEvent) {
        updateRelativeTimestamp(event.timestamp)
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

    private func updateHoverPresentation() {
        hoverBackground.layer?.backgroundColor = isPointerHovering
            ? NSColor.labelColor.withAlphaComponent(0.05).cgColor
            : NSColor.clear.cgColor
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

    static func displayTitle(for event: VaultHistoryEvent) -> String {
        let singleLine = VaultHistoryDisplayText.singleLine(event.title)
        guard singleLine.isEmpty else { return truncated(singleLine, maximumLength: 240) }
        switch event.kind {
        case .windowOpened, .windowClosed:
            return String(localized: "vaultHistory.window", defaultValue: "Window")
        default:
            return String(localized: "vaultHistory.untitled", defaultValue: "Untitled")
        }
    }

    private static func truncated(_ value: String, maximumLength: Int) -> String {
        guard value.count > maximumLength else { return value }
        return String(value.prefix(maximumLength)) + "…"
    }

    static func displaySubtitle(for event: VaultHistoryEvent) -> String {
        var parts: [String] = []
        if event.kind == .sessionActivity {
            if let displayName = event.subject.agentDisplayName, !displayName.isEmpty {
                parts.append(VaultHistoryDisplayText.singleLine(displayName))
            } else if let raw = event.subject.agent, let agent = SessionAgent(rawValue: raw) {
                parts.append(agent.displayName)
            } else {
                parts.append(event.kind.label)
            }
        } else {
            parts.append(event.kind.label)
        }
        if event.kind == .workspaceRenamed,
           let previousTitle = event.previousTitle,
           !previousTitle.isEmpty {
            parts.append(String(
                format: String(localized: "vaultHistory.detail.renamedFrom", defaultValue: "was “%@”"),
                VaultHistoryDisplayText.singleLine(previousTitle)
            ))
        }
        if let count = event.workspaceCount {
            parts.append(workspaceCountLabel(count))
        }
        if let directory = event.subject.directory, !directory.isEmpty {
            let component = (directory as NSString).lastPathComponent
            if !component.isEmpty, component != "." {
                parts.append(VaultHistoryDisplayText.singleLine(component))
            }
        }
        return VaultHistoryDisplayText.singleLine(parts.joined(separator: " · "))
    }

    private static func workspaceCountLabel(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "vaultHistory.workspaceCount.one", defaultValue: "1 workspace")
        }
        return String.localizedStringWithFormat(
            String(localized: "vaultHistory.workspaceCount.other", defaultValue: "%d workspaces"),
            count
        )
    }
}

enum VaultHistoryDisplayText {
    static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private final class VaultHistoryHitTransparentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
