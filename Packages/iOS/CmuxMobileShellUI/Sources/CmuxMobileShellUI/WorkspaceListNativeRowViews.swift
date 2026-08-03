#if os(iOS)
import CmuxMobileChanges
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import UIKit

@MainActor
final class WorkspaceListNativeCell: UITableViewCell {
    private var hostedView: UIView?
    private var hostedConstraints: [NSLayoutConstraint] = []

    func setHostedView(_ view: UIView, margins: NSDirectionalEdgeInsets) {
        NSLayoutConstraint.deactivate(hostedConstraints)
        hostedView?.removeFromSuperview()

        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        hostedConstraints = [
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margins.leading),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margins.trailing),
            view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: margins.top),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -margins.bottom),
        ]
        NSLayoutConstraint.activate(hostedConstraints)
        hostedView = view
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        accessibilityIdentifier = nil
        accessibilityCustomActions = nil
    }
}

@MainActor
final class WorkspaceNativeActionButton: UIButton {
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(activate), for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setAction(_ action: (() -> Void)?) {
        self.action = action
        isUserInteractionEnabled = action != nil
    }

    @objc
    private func activate() {
        action?()
    }
}

@MainActor
final class WorkspaceNativeUnreadDot: UIView {
    static let gutterWidth: CGFloat = 10
    static let dotDiameter: CGFloat = 11

    private let dot = UIView()
    private var centerConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = false

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = .tintColor
        dot.layer.cornerRadius = Self.dotDiameter / 2
        addSubview(dot)
        centerConstraint = dot.centerXAnchor.constraint(equalTo: centerXAnchor)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.gutterWidth),
            dot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Self.dotDiameter),
            centerConstraint,
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(isUnread: Bool, leftShift: Double) {
        dot.isHidden = !isUnread
        centerConstraint.constant = -CGFloat(leftShift)
    }
}

@MainActor
final class WorkspaceChangesChipNativeView: UIControl {
    private let primaryLabel = UILabel()
    private let secondaryLabel = UILabel()
    private let stack = UIStackView()
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText

        layer.cornerRadius = 10
        backgroundColor = .secondarySystemFill

        for label in [primaryLabel, secondaryLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 1
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 3
        stack.alignment = .center
        stack.addArrangedSubview(primaryLabel)
        stack.addArrangedSubview(secondaryLabel)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        addTarget(self, action: #selector(activate), for: .primaryActionTriggered)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (self: WorkspaceChangesChipNativeView, _) in
            self.updateColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        chip: MobileWorkspaceChangesChip,
        workspaceID: String,
        action: (() -> Void)?
    ) {
        let text = WorkspaceChangesChipTextPolicy().text(
            filesChanged: chip.filesChanged,
            additions: chip.additions,
            deletions: chip.deletions
        )
        primaryLabel.text = text.primary
        secondaryLabel.text = text.secondary
        secondaryLabel.isHidden = text.secondary == nil

        updateColors()

        let fileCount = WorkspaceChangesChipTextPolicy().fileCountText(chip.filesChanged)
        accessibilityLabel = String(
            format: String(
                localized: "workspace.changes.chip.accessibility",
                defaultValue: "Changes: %1$@, +%2$lld, −%3$lld",
                bundle: .module
            ),
            fileCount,
            chip.additions,
            chip.deletions
        )
        accessibilityIdentifier = "MobileChangesChip-\(workspaceID)"
        self.action = action
        isUserInteractionEnabled = action != nil
        accessibilityTraits = action == nil ? .staticText : .button
        if action != nil {
            NSLayoutConstraint.activate([
                widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
                heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ])
        }
    }

    @objc
    private func activate() {
        action?()
    }

    private static func uiColor(_ token: ChangesColor) -> UIColor {
        UIColor(red: token.red, green: token.green, blue: token.blue, alpha: token.alpha)
    }

    private func updateColors() {
        guard secondaryLabel.text != nil else {
            primaryLabel.textColor = .secondaryLabel
            return
        }
        let theme = ChangesTheme(
            appearance: traitCollection.userInterfaceStyle == .dark ? .dark : .light
        )
        primaryLabel.textColor = Self.uiColor(theme.addedStatus)
        secondaryLabel.textColor = Self.uiColor(theme.deletedStatus)
    }
}

@MainActor
final class WorkspaceNativeRowView: UIView {
    private static let unreadDotRailVisualGap: CGFloat = 8
    private static let railTextVisualGap: CGFloat = 10

    private let unreadDot = WorkspaceNativeUnreadDot()
    private let railContainer = UIView()
    private let rail = UIView()
    private let textStack = UIStackView()
    private let titleStack = UIStackView()
    private let pinImage = UIImageView(image: UIImage(systemName: "pin.fill"))
    private let nameLabel = UILabel()
    private let timestampLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let previewStack = UIStackView()
    private let previewLabel = UILabel()
    private var changesChip: WorkspaceChangesChipNativeView?
    private var previewHeightConstraint: NSLayoutConstraint!
    private var descriptionHeightConstraint: NSLayoutConstraint!
    private var customizeAction: (() -> Void)?
    private var pinAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 14

        railContainer.translatesAutoresizingMaskIntoConstraints = false
        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.layer.cornerRadius = 1.5
        railContainer.addSubview(rail)
        NSLayoutConstraint.activate([
            railContainer.widthAnchor.constraint(equalToConstant: 3),
            rail.leadingAnchor.constraint(equalTo: railContainer.leadingAnchor),
            rail.trailingAnchor.constraint(equalTo: railContainer.trailingAnchor),
            rail.topAnchor.constraint(equalTo: railContainer.topAnchor, constant: 5),
            rail.bottomAnchor.constraint(equalTo: railContainer.bottomAnchor, constant: -5),
        ])

        pinImage.tintColor = .secondaryLabel
        pinImage.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption2)
        pinImage.setContentHuggingPriority(.required, for: .horizontal)

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timestampLabel.font = .preferredFont(forTextStyle: .subheadline)
        timestampLabel.adjustsFontForContentSizeCategory = true
        timestampLabel.textColor = .secondaryLabel
        timestampLabel.numberOfLines = 1
        timestampLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleStack.axis = .horizontal
        titleStack.alignment = .firstBaseline
        titleStack.spacing = 8
        titleStack.addArrangedSubview(pinImage)
        titleStack.addArrangedSubview(nameLabel)
        titleStack.addArrangedSubview(timestampLabel)

        descriptionLabel.font = .preferredFont(forTextStyle: .subheadline)
        descriptionLabel.adjustsFontForContentSizeCategory = true
        descriptionLabel.numberOfLines = 2
        descriptionHeightConstraint = descriptionLabel.heightAnchor.constraint(
            greaterThanOrEqualToConstant: descriptionLabel.font.lineHeight * 2
        )
        descriptionHeightConstraint.isActive = true

        previewLabel.font = .preferredFont(forTextStyle: .subheadline)
        previewLabel.adjustsFontForContentSizeCategory = true
        previewLabel.textColor = .secondaryLabel
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewHeightConstraint = previewLabel.heightAnchor.constraint(
            greaterThanOrEqualToConstant: previewLabel.font.lineHeight * 2
        )
        previewHeightConstraint.isActive = true

        previewStack.axis = .horizontal
        previewStack.alignment = .top
        previewStack.spacing = 8
        previewStack.addArrangedSubview(previewLabel)

        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 4
        textStack.addArrangedSubview(titleStack)
        textStack.addArrangedSubview(descriptionLabel)
        textStack.addArrangedSubview(previewStack)

        addSubview(unreadDot)
        addSubview(railContainer)
        addSubview(textStack)
        NSLayoutConstraint.activate([
            unreadDot.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            unreadDot.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            unreadDot.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),

            railContainer.leadingAnchor.constraint(
                equalTo: unreadDot.trailingAnchor,
                constant: Self.unreadDotRailVisualGap
            ),
            railContainer.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            railContainer.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),

            textStack.leadingAnchor.constraint(
                equalTo: railContainer.trailingAnchor,
                constant: Self.railTextVisualGap
            ),
            textStack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        workspace: MobileWorkspacePreview,
        connectionStatus: MobileMacConnectionStatus,
        isSelected: Bool,
        changes: MobileWorkspaceChangesChip?,
        onOpenChanges: (() -> Void)?,
        wrapWorkspaceTitles: Bool,
        previewLineLimit: Int,
        unreadIndicatorLeftShift: Double,
        customizeOrRename: (() -> Void)?,
        customizeOrRenameTitle: String?,
        setPinned: ((Bool) -> Void)?
    ) {
        directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 8,
            leading: isSelected ? 10 : 0,
            bottom: 8,
            trailing: isSelected ? 10 : 0
        )
        backgroundColor = isSelected ? UIColor.tintColor.withAlphaComponent(0.14) : .clear
        unreadDot.configure(isUnread: workspace.hasUnread, leftShift: unreadIndicatorLeftShift)
        rail.backgroundColor = workspace.customColorHex.flatMap(UIColor.init(workspaceHexString:)) ?? .clear

        pinImage.isHidden = !workspace.isPinned
        nameLabel.text = workspace.name
        nameLabel.textColor = isSelected ? .tintColor : .label
        nameLabel.numberOfLines = wrapWorkspaceTitles ? 0 : 1
        timestampLabel.text = workspace.timestampOrStatus(connectionStatus: connectionStatus)

        descriptionLabel.text = workspace.displayDescription
        descriptionLabel.isHidden = workspace.displayDescription == nil
        descriptionHeightConstraint.isActive = workspace.displayDescription != nil

        let resolvedPreviewLines = max(1, previewLineLimit)
        previewLabel.text = workspace.previewLine
        previewLabel.numberOfLines = resolvedPreviewLines
        previewHeightConstraint.constant = previewLabel.font.lineHeight * CGFloat(resolvedPreviewLines)

        if let oldChip = changesChip {
            previewStack.removeArrangedSubview(oldChip)
            oldChip.removeFromSuperview()
            changesChip = nil
        }
        if let changes, changes.filesChanged > 0 {
            let chip = WorkspaceChangesChipNativeView()
            chip.configure(
                chip: changes,
                workspaceID: workspace.rpcWorkspaceID.rawValue,
                action: onOpenChanges
            )
            previewStack.addArrangedSubview(chip)
            changesChip = chip
        }

        let summary = workspace.accessibilitySummary(connectionStatus: connectionStatus)
        accessibilityIdentifier = "MobileWorkspaceRow-\(workspace.id.rawValue)"
        accessibilityLabel = workspace.name
        accessibilityValue = summary
        accessibilityTraits = .button

        if onOpenChanges == nil {
            isAccessibilityElement = true
            textStack.isAccessibilityElement = false
        } else {
            isAccessibilityElement = false
            textStack.isAccessibilityElement = true
            textStack.accessibilityLabel = workspace.name
            textStack.accessibilityValue = summary
            textStack.accessibilityTraits = .button
        }

        customizeAction = customizeOrRename
        pinAction = setPinned.map { action in { action(!workspace.isPinned) } }
        var customActions: [UIAccessibilityCustomAction] = []
        if customizeAction != nil, let customizeOrRenameTitle {
            customActions.append(UIAccessibilityCustomAction(
                name: customizeOrRenameTitle,
                target: self,
                selector: #selector(performCustomize)
            ))
        }
        if pinAction != nil {
            customActions.append(UIAccessibilityCustomAction(
                name: workspace.isPinned
                    ? L10n.string("mobile.workspace.unpin", defaultValue: "Unpin")
                    : L10n.string("mobile.workspace.pin", defaultValue: "Pin"),
                target: self,
                selector: #selector(performPin)
            ))
        }
        accessibilityCustomActions = customActions
        textStack.accessibilityCustomActions = customActions
    }

    @objc
    private func performCustomize() -> Bool {
        customizeAction?()
        return customizeAction != nil
    }

    @objc
    private func performPin() -> Bool {
        pinAction?()
        return pinAction != nil
    }
}

@MainActor
final class WorkspaceNativeGroupHeaderView: UIView {
    private let unreadDot = WorkspaceNativeUnreadDot()
    private let disclosureButton = WorkspaceNativeActionButton(type: .system)
    private let anchorButton = WorkspaceNativeActionButton(type: .system)
    private let nameLabel = UILabel()
    private let pinImage = UIImageView(image: UIImage(systemName: "pin.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 6
        accessibilityElementsHidden = false

        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.tintColor = .secondaryLabel
        NSLayoutConstraint.activate([
            disclosureButton.widthAnchor.constraint(equalToConstant: 22),
            disclosureButton.heightAnchor.constraint(equalToConstant: 22),
        ])

        let folder = UIImageView(image: UIImage(systemName: "folder.fill"))
        folder.tintColor = .secondaryLabel
        folder.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        pinImage.tintColor = .secondaryLabel
        pinImage.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)

        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let anchorStack = UIStackView(arrangedSubviews: [folder, nameLabel, pinImage])
        anchorStack.translatesAutoresizingMaskIntoConstraints = false
        anchorStack.axis = .horizontal
        anchorStack.alignment = .center
        anchorStack.spacing = 6
        anchorStack.isUserInteractionEnabled = false
        anchorButton.addSubview(anchorStack)
        NSLayoutConstraint.activate([
            anchorStack.leadingAnchor.constraint(equalTo: anchorButton.leadingAnchor),
            anchorStack.trailingAnchor.constraint(lessThanOrEqualTo: anchorButton.trailingAnchor),
            anchorStack.topAnchor.constraint(equalTo: anchorButton.topAnchor),
            anchorStack.bottomAnchor.constraint(equalTo: anchorButton.bottomAnchor),
        ])

        let row = UIStackView(arrangedSubviews: [unreadDot, disclosureButton, anchorButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(value: WorkspaceGroupHeaderRowValue, actions: WorkspaceGroupHeaderRowActions) {
        let group = value.group
        unreadDot.configure(isUnread: value.hasUnread, leftShift: value.unreadIndicatorLeftShift)
        nameLabel.text = group.name
        pinImage.isHidden = !group.isPinned
        backgroundColor = value.navigationStyle == .sidebar && value.isAnchorSelected
            ? UIColor.label.withAlphaComponent(0.08)
            : .clear
        accessibilityIdentifier = "MobileWorkspaceGroupHeader-\(group.id.rawValue)"

        disclosureButton.setImage(
            UIImage(systemName: group.isCollapsed ? "chevron.right" : "chevron.down"),
            for: .normal
        )
        disclosureButton.accessibilityLabel = group.isCollapsed
            ? L10n.string("mobile.workspaceGroup.expand.a11y", defaultValue: "Expand group")
            : L10n.string("mobile.workspaceGroup.collapse.a11y", defaultValue: "Collapse group")
        disclosureButton.accessibilityIdentifier = "MobileWorkspaceGroupDisclosure-\(group.id.rawValue)"
        disclosureButton.accessibilityTraits = value.canToggleCollapsed ? .button : .image
        if value.canToggleCollapsed, let toggle = actions.toggleCollapsed {
            disclosureButton.setAction { toggle(group.id, !group.isCollapsed) }
        } else {
            disclosureButton.setAction(nil)
        }

        anchorButton.accessibilityLabel = group.name
        anchorButton.accessibilityValue = value.hasUnread
            ? L10n.string("mobile.workspace.unread", defaultValue: "Unread")
            : ""
        anchorButton.accessibilityTraits = .button
        anchorButton.setAction { actions.selectWorkspace(group.anchorWorkspaceID) }
    }
}

@MainActor
final class WorkspaceNativeGroupFooterView: UIView {
    init(groupName: String?, showsBoundary: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        let format = L10n.string(
            "mobile.workspaceGroup.footer.a11y.label",
            defaultValue: "End of %@"
        )
        let name = groupName ?? L10n.string(
            "mobile.workspaceGroup.footer.a11y.fallback",
            defaultValue: "group"
        )
        accessibilityLabel = String(format: format, name)
        accessibilityHint = L10n.string(
            "mobile.workspaceGroup.footer.a11y.hint",
            defaultValue: "Drop above to add to the group, or below to place this workspace at the top level."
        )

        let boundary = UIView()
        boundary.translatesAutoresizingMaskIntoConstraints = false
        boundary.backgroundColor = .separator
        boundary.layer.cornerRadius = 1
        boundary.alpha = showsBoundary ? 1 : 0
        addSubview(boundary)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 16),
            boundary.leadingAnchor.constraint(equalTo: leadingAnchor),
            boundary.trailingAnchor.constraint(equalTo: trailingAnchor),
            boundary.centerYAnchor.constraint(equalTo: centerYAnchor),
            boundary.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class WorkspaceNativeFilterEmptyView: UIView {
    init(filter: MobileWorkspaceListFilter, showAll: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "MobileWorkspaceFilterEmpty"

        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = filter.emptyStateText ?? ""

        let button = WorkspaceNativeActionButton(type: .system)
        button.setTitle(L10n.string("mobile.workspaces.filter.showAll", defaultValue: "Show All"), for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        button.accessibilityIdentifier = "MobileWorkspaceFilterShowAll"
        button.setAction(showAll)

        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class WorkspaceNativeRecoveryView: UIView {
    init(error: String?, signOut: (() -> Void)?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "MobileConnectionReauthRow"

        let icon = UIImageView(image: UIImage(systemName: "person.crop.circle.badge.exclamationmark"))
        icon.tintColor = .systemOrange
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let message = UILabel()
        message.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        message.adjustsFontForContentSizeCategory = true
        message.numberOfLines = 0
        message.text = error ?? L10n.string(
            "mobile.recovery.accountMismatch",
            defaultValue: "This computer is signed in to a different cmux account. Sign out and sign back in with that account."
        )

        let messageRow = UIStackView(arrangedSubviews: [icon, message])
        messageRow.axis = .horizontal
        messageRow.alignment = .top
        messageRow.spacing = 10

        let stack = UIStackView(arrangedSubviews: [messageRow])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        if let signOut {
            let button = WorkspaceNativeActionButton(type: .system)
            var config = UIButton.Configuration.filled()
            config.title = L10n.string("mobile.recovery.switchAccount", defaultValue: "Sign Out & Switch Account")
            config.cornerStyle = .medium
            button.configuration = config
            button.accessibilityIdentifier = "MobileConnectionReauthSignOut"
            button.setAction(signOut)
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class WorkspaceNativeConnectionStatusView: UIView {
    init(
        host: String,
        status: MobileMacConnectionStatus,
        showsSpinner: Bool,
        titleOverride: String?,
        descriptionOverride: String?,
        retry: (() -> Void)?,
        addDevice: (() -> Void)?,
        reconnect: (() -> Void)?
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "MobileMacConnectionStatus"

        let leading: UIView
        if showsSpinner || status == .reconnecting {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            spinner.isAccessibilityElement = false
            leading = spinner
        } else {
            let icon = UIImageView(image: UIImage(systemName: status.symbolName))
            icon.tintColor = status.nativeTintColor
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)
            leading = icon
        }
        leading.translatesAutoresizingMaskIntoConstraints = false
        leading.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let title = UILabel()
        title.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 1
        title.text = titleOverride ?? status.label

        let detail = UILabel()
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        detail.text = descriptionOverride ?? (host.isEmpty ? status.description : host)

        let labels = UIStackView(arrangedSubviews: [title, detail])
        labels.axis = .vertical
        labels.spacing = 2
        let header = UIStackView(arrangedSubviews: [leading, labels])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 10

        let stack = UIStackView(arrangedSubviews: [header])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 10

        var actionButtons: [UIView] = []
        if let retry {
            actionButtons.append(Self.button(
                title: L10n.string("mobile.common.retry", defaultValue: "Retry"),
                identifier: "MobileInitialConnectionRetry",
                style: .filled,
                action: retry
            ))
        }
        if let addDevice {
            actionButtons.append(Self.button(
                title: L10n.string("mobile.addDevice.title", defaultValue: "Add Computer"),
                identifier: "MobileInitialConnectionAddDevice",
                style: .tinted,
                action: addDevice
            ))
        }
        if status == .unavailable, let reconnect {
            actionButtons.append(Self.button(
                title: L10n.string("mobile.workspace.reconnect", defaultValue: "Reconnect"),
                identifier: "MobileMacReconnectButton",
                style: .plain,
                action: reconnect
            ))
        }
        if !actionButtons.isEmpty {
            let actions = UIStackView(arrangedSubviews: actionButtons)
            actions.axis = .horizontal
            actions.alignment = .center
            actions.spacing = 10
            let inset = UIView()
            inset.addSubview(actions)
            actions.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                actions.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 34),
                actions.trailingAnchor.constraint(lessThanOrEqualTo: inset.trailingAnchor),
                actions.topAnchor.constraint(equalTo: inset.topAnchor),
                actions.bottomAnchor.constraint(equalTo: inset.bottomAnchor),
            ])
            stack.addArrangedSubview(inset)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        isAccessibilityElement = actionButtons.isEmpty
        if actionButtons.isEmpty {
            accessibilityLabel = [title.text, detail.text]
                .compactMap { $0 }
                .joined(separator: ", ")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private enum ButtonStyle {
        case filled
        case tinted
        case plain
    }

    private static func button(
        title: String,
        identifier: String,
        style: ButtonStyle,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = WorkspaceNativeActionButton(type: .system)
        var configuration: UIButton.Configuration
        switch style {
        case .filled: configuration = .filled()
        case .tinted: configuration = .tinted()
        case .plain: configuration = .plain()
        }
        configuration.title = title
        configuration.cornerStyle = .medium
        button.configuration = configuration
        button.accessibilityIdentifier = identifier
        button.setAction(action)
        return button
    }
}

@MainActor
final class WorkspaceGroupRenameViewController: UITableViewController, UITextFieldDelegate {
    private let onSave: (String) -> Void
    let nameField = UITextField()
    private let fieldCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private(set) lazy var saveButton = UIBarButtonItem(
        title: L10n.string("mobile.common.save", defaultValue: "Save"),
        style: .done,
        target: self,
        action: #selector(save)
    )

    init(currentName: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        super.init(style: .insetGrouped)
        nameField.text = currentName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.string("mobile.workspaceGroup.rename.title", defaultValue: "Rename Group")
        navigationItem.largeTitleDisplayMode = .never

        let cancel = UIBarButtonItem(
            title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"),
            style: .plain,
            target: self,
            action: #selector(cancel)
        )
        cancel.accessibilityIdentifier = "WorkspaceGroupRenameCancelButton"
        saveButton.accessibilityIdentifier = "WorkspaceGroupRenameSaveButton"
        navigationItem.leftBarButtonItem = cancel
        navigationItem.rightBarButtonItem = saveButton

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholder = L10n.string("mobile.workspaceGroup.rename.placeholder", defaultValue: "Group name")
        nameField.autocorrectionType = .no
        nameField.returnKeyType = .done
        nameField.delegate = self
        nameField.accessibilityIdentifier = "WorkspaceGroupRenameField"
        nameField.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
        fieldCell.contentView.addSubview(nameField)
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: fieldCell.contentView.layoutMarginsGuide.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: fieldCell.contentView.layoutMarginsGuide.trailingAnchor),
            nameField.topAnchor.constraint(equalTo: fieldCell.contentView.topAnchor, constant: 10),
            nameField.bottomAnchor.constraint(equalTo: fieldCell.contentView.bottomAnchor, constant: -10),
        ])
        nameChanged()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        fieldCell
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        save()
        return false
    }

    @objc
    private func nameChanged() {
        saveButton.isEnabled = !trimmedName.isEmpty
    }

    @objc
    private func save() {
        guard !trimmedName.isEmpty else { return }
        onSave(trimmedName)
        dismiss(animated: true)
    }

    @objc
    private func cancel() {
        dismiss(animated: true)
    }

    private var trimmedName: String {
        (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension UIColor {
    convenience init?(workspaceHexString: String) {
        var hex = workspaceHexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        switch hex.count {
        case 3:
            red = CGFloat((value >> 8) & 0xF) / 15
            green = CGFloat((value >> 4) & 0xF) / 15
            blue = CGFloat(value & 0xF) / 15
            alpha = 1
        case 6:
            red = CGFloat((value >> 16) & 0xFF) / 255
            green = CGFloat((value >> 8) & 0xFF) / 255
            blue = CGFloat(value & 0xFF) / 255
            alpha = 1
        case 8:
            red = CGFloat((value >> 24) & 0xFF) / 255
            green = CGFloat((value >> 16) & 0xFF) / 255
            blue = CGFloat((value >> 8) & 0xFF) / 255
            alpha = CGFloat(value & 0xFF) / 255
        default:
            return nil
        }
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

private extension MobileMacConnectionStatus {
    var nativeTintColor: UIColor {
        switch self {
        case .connected: .systemGreen
        case .reconnecting: .systemOrange
        case .unavailable: .systemRed
        }
    }
}
#endif
