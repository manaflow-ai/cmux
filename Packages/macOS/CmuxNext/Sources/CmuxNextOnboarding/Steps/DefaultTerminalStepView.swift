import AppKit
import CmuxNextDesign

/// Step 4: each thing cmux can take over from Terminal, with its own state,
/// plus the Finder service and an honest note about what stays with Terminal.
final class DefaultTerminalStepView: NSView {
    private let model: DefaultAppsStepModel
    private var rows: [DefaultHandlerClaim: ClaimRowView] = [:]
    private let useAll: OnboardingButton
    private var loop: RenderLoop?

    init(model: DefaultAppsStepModel) {
        self.model = model
        useAll = OnboardingButton(OnboardingStrings.useAll, style: .primary)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        useAll.onPress = { [weak model] in model?.requestAllTerminalClaims() }
        let list = ThemedView()
        list.fill = { Palette.hoverFill }
        list.border = { Palette.separator }
        list.cornerRadius = OnboardingMetrics.cornerRadius
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let symbols: [DefaultHandlerClaim: String] = [.ssh: "network", .manPage: "book.closed", .shellScripts: "terminal"]
        for claim in DefaultHandlerClaim.terminalClaims {
            let row = ClaimRowView(symbol: symbols[claim] ?? "terminal", title: OnboardingStrings.claimTitle(claim), detail: OnboardingStrings.claimDetail(claim))
            row.action.onPress = { [weak model] in model?.request(claim) }
            rows[claim] = row
            stack.addArrangedSubview(row)
            stack.addArrangedSubview(SeparatorView())
        }
        let service = ClaimRowView(symbol: "folder.badge.plus", title: OnboardingStrings.serviceTitle, detail: OnboardingStrings.serviceDetail)
        service.action.title = OnboardingStrings.openSettings
        service.action.onPress = { [weak model] in model?.openServicesSettings() }
        stack.addArrangedSubview(service)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        list.addSubview(stack)
        let limits = OnboardingLabel.make(OnboardingStrings.terminalLimits, font: Typography.caption, color: Palette.textTertiary, lines: 3)
        let outer = NSStackView(views: [list, limits])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = Metrics.space5
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        addSubview(useAll)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: list.leadingAnchor), stack.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            stack.topAnchor.constraint(equalTo: list.topAnchor), stack.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor), outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: useAll.bottomAnchor, constant: Metrics.space5),
            list.widthAnchor.constraint(equalTo: outer.widthAnchor),
            limits.widthAnchor.constraint(equalTo: outer.widthAnchor),
            useAll.topAnchor.constraint(equalTo: topAnchor),
            useAll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func render() {
        for (claim, row) in rows {
            row.setState(claimed: model.isClaimed(claim), pending: model.pending.contains(claim), error: model.errors[claim])
        }
        useAll.isHidden = DefaultHandlerClaim.terminalClaims.allSatisfy(model.isClaimed)
    }
}

/// Symbol, title, detail and a trailing action or "In Use" status.
final class ClaimRowView: NSView {
    let action = OnboardingButton(OnboardingStrings.use, style: .secondary)
    private let detailLabel: NSTextField
    private let detailText: String
    private let status = OnboardingLabel.make(OnboardingStrings.inUse, font: Typography.caption, color: Palette.textSecondary)
    private let statusIcon = NSImageView()

    init(symbol: String, title: String, detail: String) {
        detailText = detail
        detailLabel = OnboardingLabel.make(detail, font: Typography.caption, color: Palette.textTertiary)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: Metrics.iconSize + 2, weight: .regular)
        icon.contentTintColor = Palette.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = OnboardingLabel.make(title, font: Typography.bodyEmphasized)
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.space1
        statusIcon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        statusIcon.contentTintColor = Palette.success
        let statusRow = NSStackView(views: [statusIcon, status])
        statusRow.spacing = Metrics.space2
        let row = NSStackView(views: [icon, text, FlexibleSpace(), statusRow, action])
        row.spacing = Metrics.space5
        row.edgeInsets = NSEdgeInsets(top: Metrics.space5, left: Metrics.space6, bottom: Metrics.space5, right: Metrics.space5)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: Metrics.space6 + Metrics.space2),
        ])
        statusRow.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setState(claimed: Bool, pending: Bool, error: String?) {
        action.isHidden = claimed
        action.isEnabled = !pending
        status.superview?.isHidden = !claimed
        detailLabel.stringValue = error.map(OnboardingStrings.systemRefused) ?? detailText
        detailLabel.textColor = error == nil ? Palette.textTertiary : Palette.danger
    }
}

/// A hairline between list rows.
final class SeparatorView: ThemedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        fill = { Palette.separator }
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
}
