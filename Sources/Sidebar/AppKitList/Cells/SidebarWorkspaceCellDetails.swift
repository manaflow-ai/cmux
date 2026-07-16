import AppKit
import CmuxFoundation
import CmuxSidebar
import Foundation

/// The auxiliary detail lines under the title row that need no pooling logic
/// of their own: custom description, latest notification/iMessage subtitle,
/// remote SSH line, latest log line, progress bar, and listening ports.
/// Branch/directory and pull requests live in their own files.
///
/// Not a view itself: it owns the detail views the cell's content stack
/// adopts, and fans configure updates out to them. All rows live in a
/// `.width`-aligned vertical stack, so no constraint crosses a row boundary
/// (hidden rows detach from the stack, which would sever such constraints).
@MainActor
final class SidebarWorkspaceCellDetails {
    private static let maxDescriptionLines = 12
    private static let maxDescriptionCharacters = 4096

    let descriptionLabel = SidebarWorkspaceCellLabel()
    let subtitleLabel = SidebarWorkspaceCellLabel()

    let remoteRow = SidebarWorkspaceCellStackFactory.horizontal(spacing: 6)
    private let remoteHostLabel = SidebarWorkspaceCellLabel()
    private let remoteStatusLabel = SidebarWorkspaceCellLabel()
    private let remoteReconnectButton = SidebarWorkspaceCellButton()

    let logRow = SidebarWorkspaceCellStackFactory.horizontal(spacing: 4)
    private let logIcon = SidebarWorkspaceCellIconView()
    private let logLabel = SidebarWorkspaceCellLabel()

    let progressColumn = SidebarWorkspaceCellStackFactory.vertical(spacing: 2, alignment: .width)
    private let progressBar = SidebarWorkspaceCellProgressBarView()
    private let progressLabel = SidebarWorkspaceCellLabel()
    private lazy var progressBarHeight = progressBar.heightAnchor.constraint(equalToConstant: 3)

    let portsRow = SidebarWorkspaceCellStackFactory.horizontal(spacing: 4)
    private let portsPool = SidebarWorkspaceCellRowPool<SidebarWorkspaceCellButton>()
    private let portsSpacer = NSView()

    init() {
        descriptionLabel.wrapsText = true
        descriptionLabel.maximumNumberOfLines = Self.maxDescriptionLines
        descriptionLabel.setAccessibilityIdentifier("SidebarWorkspaceDescriptionText")

        subtitleLabel.wrapsText = true

        remoteHostLabel.lineBreakMode = .byTruncatingMiddle
        remoteStatusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        remoteStatusLabel.setContentHuggingPriority(.required, for: .horizontal)
        remoteReconnectButton.imagePosition = .imageLeading
        remoteReconnectButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        remoteReconnectButton.setContentHuggingPriority(.required, for: .horizontal)
        remoteRow.addArrangedSubview(remoteHostLabel)
        remoteRow.addArrangedSubview(remoteStatusLabel)
        remoteRow.addArrangedSubview(remoteReconnectButton)

        logRow.addArrangedSubview(logIcon)
        logRow.addArrangedSubview(logLabel)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBarHeight.isActive = true
        progressColumn.addArrangedSubview(progressBar)
        progressColumn.addArrangedSubview(progressLabel)

        portsSpacer.translatesAutoresizingMaskIntoConstraints = false
        portsSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        portsRow.addArrangedSubview(portsSpacer)
    }

    func update(_ context: SidebarWorkspaceCellContext) {
        updateDescription(context)
        updateSubtitle(context)
        updateRemote(context)
        updateLog(context)
        updateProgress(context)
        updatePorts(context)
    }

    private func updateDescription(_ context: SidebarWorkspaceCellContext) {
        guard let description = context.workspace.customDescription else {
            descriptionLabel.isHidden = true
            return
        }
        descriptionLabel.isHidden = false
        let style = context.style
        let display = description.sidebarCellBoundedDisplayString(
            maxDisplayedLines: Self.maxDescriptionLines,
            maxDisplayedCharacters: Self.maxDescriptionCharacters
        )
        let font = SidebarWorkspaceCellFonts.system(
            style.environment.fontSize(base: 10.5, sidebarFontScale: style.fontScale)
        )
        let color = style.descriptionForeground
        if let rendered = SidebarMarkdownRenderer(markdown: display).workspaceDescription {
            descriptionLabel.attributedStringValue = SidebarWorkspaceCellMarkdown.nsAttributed(
                from: rendered,
                baseFont: font,
                color: color
            )
        } else {
            descriptionLabel.font = font
            descriptionLabel.textColor = color
            descriptionLabel.stringValue = display
        }
    }

    private func updateSubtitle(_ context: SidebarWorkspaceCellContext) {
        let settings = context.settings
        let latestNotificationSubtitle = context.snapshot.latestNotificationText
        let conversationMessageSubtitle: String? = {
            guard !settings.hidesAllDetails, settings.iMessageModeEnabled else { return nil }
            let trimmed = context.workspace.latestConversationMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }()
        let effectiveSubtitle = latestNotificationSubtitle ?? conversationMessageSubtitle
        let subtitleLineLimit = latestNotificationSubtitle == nil
            ? 2
            : settings.notificationMessageLineLimit
        guard let effectiveSubtitle else {
            subtitleLabel.isHidden = true
            return
        }
        subtitleLabel.isHidden = false
        subtitleLabel.maximumNumberOfLines = subtitleLineLimit
        subtitleLabel.font = SidebarWorkspaceCellFonts.system(context.style.fontSize(10))
        subtitleLabel.textColor = context.style.secondary(0.8)
        subtitleLabel.stringValue = effectiveSubtitle.sidebarCellBoundedDisplayString(
            maxDisplayedLines: subtitleLineLimit,
            maxDisplayedCharacters: 4096
        )
    }

    private func updateRemote(_ context: SidebarWorkspaceCellContext) {
        let settings = context.settings
        let workspace = context.workspace
        guard !settings.hidesAllDetails,
              settings.showsSSH,
              let remoteText = workspace.remoteWorkspaceSidebarText else {
            remoteRow.isHidden = true
            return
        }
        remoteRow.isHidden = false
        let style = context.style

        remoteHostLabel.font = SidebarWorkspaceCellFonts.monospaced(style.fontSize(10))
        remoteHostLabel.textColor = style.secondary(0.8)
        remoteHostLabel.stringValue = remoteText

        remoteStatusLabel.font = SidebarWorkspaceCellFonts.system(style.fontSize(9), weight: .medium)
        remoteStatusLabel.textColor = style.secondary(0.58)
        remoteStatusLabel.stringValue = workspace.remoteConnectionStatusText

        remoteReconnectButton.isHidden = !workspace.showsRemoteReconnectAffordance
        if workspace.showsRemoteReconnectAffordance {
            let reconnectColor = style.secondary(0.9)
            remoteReconnectButton.image = SidebarWorkspaceCellSymbols.image(
                "arrow.clockwise",
                pointSize: style.fontSize(9),
                weight: .semibold
            )
            remoteReconnectButton.contentTintColor = reconnectColor
            remoteReconnectButton.attributedTitle = NSAttributedString(
                string: String(localized: "sidebar.remote.reconnect.button", defaultValue: "Reconnect"),
                attributes: [
                    .font: SidebarWorkspaceCellFonts.system(style.fontSize(9), weight: .semibold),
                    .foregroundColor: reconnectColor,
                ]
            )
            remoteReconnectButton.toolTip = String(
                format: String(
                    localized: "sidebar.remote.reconnect.help",
                    defaultValue: "Reconnect to %@"
                ),
                locale: .current,
                remoteText
            )
            let workspaceId = context.snapshot.workspaceId
            let actions = context.actions
            remoteReconnectButton.onPress = { actions?.reconnectTargets([workspaceId]) }
        }
        remoteRow.toolTip = workspace.remoteStateHelpText
    }

    private func updateLog(_ context: SidebarWorkspaceCellContext) {
        guard context.settings.visibleAuxiliaryDetails.showsLog,
              let latestLog = context.workspace.latestLog else {
            logRow.isHidden = true
            return
        }
        logRow.isHidden = false
        let style = context.style
        logIcon.setSymbol(
            SidebarWorkspaceCellStyle.logLevelIcon(latestLog.level),
            pointSize: style.fontSize(8),
            color: style.logLevelColor(latestLog.level)
        )
        logLabel.font = SidebarWorkspaceCellFonts.system(style.fontSize(10))
        logLabel.textColor = style.secondary(0.8)
        logLabel.stringValue = latestLog.message
    }

    private func updateProgress(_ context: SidebarWorkspaceCellContext) {
        guard context.settings.visibleAuxiliaryDetails.showsProgress,
              let progress = context.workspace.progress else {
            progressColumn.isHidden = true
            return
        }
        progressColumn.isHidden = false
        let style = context.style
        progressBarHeight.constant = max(3, style.scaledSize(3))
        progressBar.trackColor = style.progressTrack
        progressBar.fillColor = style.progressFill
        progressBar.fraction = CGFloat(max(0, min(progress.value, 1)))
        progressLabel.isHidden = progress.label == nil
        if let label = progress.label {
            progressLabel.font = SidebarWorkspaceCellFonts.system(style.fontSize(9))
            progressLabel.textColor = style.secondary(0.6)
            progressLabel.stringValue = label
        }
    }

    private func updatePorts(_ context: SidebarWorkspaceCellContext) {
        let ports = context.workspace.listeningPorts
        guard context.settings.visibleAuxiliaryDetails.showsPorts, !ports.isEmpty else {
            portsRow.isHidden = true
            return
        }
        portsRow.isHidden = false
        let style = context.style
        let actions = context.actions
        let font = SidebarWorkspaceCellFonts.monospaced(style.fontSize(10))
        let color = style.secondary(0.75)
        let buttons = portsPool.prepare(count: ports.count, in: portsRow) {
            let button = SidebarWorkspaceCellButton()
            button.imagePosition = .noImage
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            return button
        }
        // The trailing spacer must stay last so the buttons pack leading.
        portsRow.removeArrangedSubview(portsSpacer)
        portsRow.addArrangedSubview(portsSpacer)
        for (port, button) in zip(ports, buttons) {
            button.attributedTitle = NSAttributedString(
                string: SidebarPortDisplayText.label(for: port),
                attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
            )
            button.toolTip = SidebarPortDisplayText.openTooltip(for: port)
            button.onPress = { actions?.openPort(port) }
        }
    }
}
