import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation

/// Recycled pure-AppKit History group header, floated by `NSTableView`.
@MainActor
final class VaultHistoryTableGroupCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("VaultHistoryTableGroupCellView")

    private let backgroundView = NSVisualEffectView()
    private let iconView = CmuxResolvedIconImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconToTitleConstraint: NSLayoutConstraint!
    private var actionButtonWidthConstraint: NSLayoutConstraint!
    private var representedAction: VaultHistoryRowAction?
    private var onPerformAction: ((VaultHistoryRowAction) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.material = .sidebar
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .followsWindowActiveState
        addSubview(backgroundView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.cell?.wraps = false
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.maximumNumberOfLines = 1
        countLabel.usesSingleLineMode = true
        countLabel.cell?.usesSingleLineMode = true
        countLabel.cell?.wraps = false
        countLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.6)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.setAccessibilityElement(false)
        addSubview(countLabel)

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.isBordered = false
        actionButton.imagePosition = .imageOnly
        actionButton.focusRingType = .none
        actionButton.target = self
        actionButton.action = #selector(performRepresentedAction(_:))
        addSubview(actionButton)

        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 0)
        iconToTitleConstraint = titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor)
        actionButtonWidthConstraint = actionButton.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint,
            iconView.heightAnchor.constraint(equalToConstant: 12),

            iconToTitleConstraint,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -4),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButtonWidthConstraint,
            actionButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconView.apply(nil)
        configureAction(nil)
        onPerformAction = nil
    }

    func configure(
        id: String,
        title: String,
        count: Int,
        agent: SessionAgent?,
        action: VaultHistoryRowAction?,
        globalFontMagnificationPercent: Int,
        onPerformAction: @escaping (VaultHistoryRowAction) -> Void
    ) {
        self.onPerformAction = onPerformAction
        let singleLineTitle = VaultHistoryDisplayText.singleLine(title)
        titleLabel.stringValue = singleLineTitle
        titleLabel.toolTip = singleLineTitle
        titleLabel.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(11, percent: globalFontMagnificationPercent),
            weight: .semibold
        )
        countLabel.stringValue = count.formatted()
        countLabel.toolTip = countLabel.stringValue
        countLabel.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(10, percent: globalFontMagnificationPercent)
        )
        configureIcon(agent)
        configureAction(action)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("VaultHistoryGroup:\(id)")
        setAccessibilityLabel("\(singleLineTitle), \(count.formatted())")
    }

    func configureWorkspace(
        _ header: VaultHistoryTableRow.WorkspaceHeader,
        globalFontMagnificationPercent: Int,
        onPerformAction: @escaping (VaultHistoryRowAction) -> Void
    ) {
        self.onPerformAction = onPerformAction
        let singleLineTitle = VaultHistoryDisplayText.singleLine(header.title)
        let resolvedTitle = singleLineTitle.isEmpty
            ? String(localized: "vaultHistory.untitled", defaultValue: "Untitled")
            : singleLineTitle
        titleLabel.stringValue = resolvedTitle
        titleLabel.toolTip = resolvedTitle
        titleLabel.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(11, percent: globalFontMagnificationPercent),
            weight: .semibold
        )
        countLabel.stringValue = VaultHistoryDisplayText.singleLine(header.detail)
        countLabel.toolTip = countLabel.stringValue
        countLabel.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(9.5, percent: globalFontMagnificationPercent)
        )
        configureWorkspaceIcon(isActive: header.isActive)
        configureAction(header.action)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("VaultHistoryWorkspace:\(header.id)")
        setAccessibilityLabel("\(resolvedTitle), \(countLabel.stringValue)")
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
        actionButton.image = NSImage(
            systemSymbolName: action.symbolName,
            accessibilityDescription: action.label
        )?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        actionButton.contentTintColor = .secondaryLabelColor
        actionButton.toolTip = action.label
        actionButton.setAccessibilityLabel(action.label)
    }

    @objc private func performRepresentedAction(_ sender: Any?) {
        guard let representedAction else { return }
        onPerformAction?(representedAction)
    }

    private func configureIcon(_ agent: SessionAgent?) {
        guard let agent else {
            iconView.apply(nil)
            iconWidthConstraint.constant = 0
            iconToTitleConstraint.constant = 0
            return
        }
        let source: CmuxResolvedIconSource
        if let assetName = agent.assetName {
            source = .asset(name: assetName, bundle: .main)
        } else {
            source = .systemSymbol(
                name: agent.systemImageName ?? "person.crop.circle",
                accessibilityDescription: agent.displayName
            )
        }
        iconWidthConstraint.constant = 12
        iconToTitleConstraint.constant = 4
        iconView.apply(CmuxResolvedIconRequest(
            source: source,
            size: NSSize(width: 12, height: 12),
            tintColor: agent.assetName == nil ? .secondaryLabelColor : nil
        ))
    }

    private func configureWorkspaceIcon(isActive: Bool) {
        let symbolName = isActive ? "circle.fill" : "clock.arrow.circlepath"
        let description = isActive
            ? String(localized: "vaultHistory.workspace.active", defaultValue: "Active")
            : String(localized: "vaultHistory.workspace.closed", defaultValue: "Closed")
        iconWidthConstraint.constant = 12
        iconToTitleConstraint.constant = 4
        iconView.apply(CmuxResolvedIconRequest(
            source: .systemSymbol(name: symbolName, accessibilityDescription: description),
            size: NSSize(width: isActive ? 7 : 11, height: isActive ? 7 : 11),
            tintColor: isActive ? .systemGreen : .secondaryLabelColor
        ))
    }
}
