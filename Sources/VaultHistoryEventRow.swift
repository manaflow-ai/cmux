import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation

enum VaultHistoryRowAction: Equatable {
    case resumeSession(SessionEntry)
    case reopenClosedItem(UUID)

    var label: String {
        switch self {
        case .resumeSession:
            return String(localized: "sessionIndex.row.resume", defaultValue: "Resume in New Tab")
        case .reopenClosedItem:
            return String(localized: "vaultHistory.action.reopen", defaultValue: "Reopen")
        }
    }

    var symbolName: String {
        switch self {
        case .resumeSession: return "play.fill"
        case .reopenClosedItem: return "arrow.uturn.backward"
        }
    }
}

struct VaultHistoryRowActions {
    let onResume: ((SessionEntry) -> Void)?
    let onReopenClosedItem: ((UUID) -> Bool)?

    var canResume: Bool { onResume != nil }
    var canReopen: Bool { onReopenClosedItem != nil }

    func perform(_ action: VaultHistoryRowAction) {
        switch action {
        case .resumeSession(let entry): onResume?(entry)
        case .reopenClosedItem(let id): _ = onReopenClosedItem?(id)
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
    private var actionButtonWidthConstraint: NSLayoutConstraint!
    private var representedEvent: VaultHistoryEvent?
    private var representedAction: VaultHistoryRowAction?
    private var representedAgent: SessionAgent?
    private var representedFontPercent = GlobalFontMagnification.defaultPercent
    private var onPerformAction: ((VaultHistoryRowAction) -> Void)?
    private var isPointerHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true

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
            label.cell?.truncatesLastVisibleLine = true
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
        NSLayoutConstraint.activate([
            hoverBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            hoverBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            hoverBackground.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hoverBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),

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

        titleLabel.stringValue = Self.displayTitle(for: event)
        subtitleLabel.stringValue = Self.subtitle(for: event)
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
            let description = event.subject.agentDisplayName ?? agent.displayName
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
            return
        }
        iconView.apply(CmuxResolvedIconRequest(
            source: .systemSymbol(name: event.kind.symbolName, accessibilityDescription: event.kind.label),
            size: NSSize(width: 14, height: 14),
            tintColor: .secondaryLabelColor
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
        timeLabel.stringValue = Self.relativeFormatter.localizedString(
            for: event.timestamp,
            relativeTo: Date()
        )
        timeLabel.toolTip = event.timestamp.formatted(date: .abbreviated, time: .shortened)
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
        let trimmed = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return truncated(trimmed, maximumLength: 240) }
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

    private static func subtitle(for event: VaultHistoryEvent) -> String {
        var parts: [String] = []
        if event.kind == .sessionActivity {
            if let displayName = event.subject.agentDisplayName, !displayName.isEmpty {
                parts.append(displayName)
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
                previousTitle
            ))
        }
        if let count = event.workspaceCount {
            parts.append(workspaceCountLabel(count))
        }
        if let directory = event.subject.directory, !directory.isEmpty {
            let component = (directory as NSString).lastPathComponent
            if !component.isEmpty, component != "." { parts.append(component) }
        }
        return parts.joined(separator: " · ")
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

private final class VaultHistoryHitTransparentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
