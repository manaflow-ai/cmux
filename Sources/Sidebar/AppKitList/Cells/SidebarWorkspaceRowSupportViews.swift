import AppKit
import CmuxFoundation
import CmuxSidebar
import CmuxWorkspaces
import SwiftUI

/// Resolved color helpers for one row render (parity with the SwiftUI
/// active/inactive foreground rules in SidebarAppearanceSupport).
@MainActor
struct SidebarRowPalette {
    let model: SidebarWorkspaceRowModel

    var colorScheme: ColorScheme { model.colorSchemeIsDark ? .dark : .light }

    var selectedBackground: NSColor {
        sidebarSelectedWorkspaceBackgroundNSColor(
            for: colorScheme,
            sidebarSelectionColorHex: model.settings.selectionColorHex
        )
    }

    func selectedForeground(_ opacity: CGFloat) -> NSColor {
        sidebarSelectedWorkspaceForegroundNSColor(on: selectedBackground, opacity: opacity)
    }

    var primaryText: NSColor {
        model.isActive ? selectedForeground(1.0) : .labelColor
    }

    func secondary(_ opacity: CGFloat = 0.75) -> NSColor {
        model.isActive ? selectedForeground(opacity) : .secondaryLabelColor
    }

    static func attributed(_ source: AttributedString, font: NSFont, color: NSColor) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(source))
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: font, range: fullRange)
        mutable.addAttribute(.foregroundColor, value: color, range: fullRange)
        return mutable
    }
}

/// One "small icon + text" line (metadata entry, log line, branch/dir line).
@MainActor
final class SidebarRowIconTextLine: NSView {
    struct BranchLineContent {
        let branch: String?
        let directoryCandidates: [String]
        let stacked: Bool
    }

    private let iconView = NSImageView()
    private let iconLabel = NSTextField(labelWithString: "")
    private let textView = SidebarRowTextView(lines: 1)
    private let metadataButton = SidebarRowLinkButton()
    private let secondTextView = SidebarRowTextView(lines: 1)
    private var iconSize: CGFloat = 0
    private var stacked = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        addSubview(iconLabel)
        addSubview(textView)
        metadataButton.alignment = .left
        metadataButton.isHidden = true
        addSubview(metadataButton)
        secondTextView.isHidden = true
        addSubview(secondTextView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configureMetadataEntry(
        _ entry: SidebarStatusEntry,
        model: SidebarWorkspaceRowModel,
        color: NSColor,
        onOpenURL: @escaping (URL) -> Void
    ) {
        stacked = false
        secondTextView.isHidden = true
        iconLabel.isHidden = true
        iconView.isHidden = true
        iconSize = 0
        if let icon = entry.icon {
            if icon.hasPrefix("emoji:") {
                iconLabel.isHidden = false
                iconLabel.stringValue = String(icon.dropFirst("emoji:".count))
                iconLabel.font = .systemFont(ofSize: model.scaled(9))
                iconSize = model.scaled(9) + 3
            } else if icon.hasPrefix("text:") {
                iconLabel.isHidden = false
                iconLabel.stringValue = String(icon.dropFirst("text:".count))
                iconLabel.font = .systemFont(ofSize: model.scaled(8), weight: .semibold)
                iconLabel.textColor = color
                iconSize = model.scaled(8) + 3
            } else {
                let name = icon.hasPrefix("sf:") ? String(icon.dropFirst("sf:".count)) : icon
                if let image = RenderableSystemSymbol.configuredAppKitImage(
                    systemName: name, pointSize: model.scaled(8), weight: .medium
                ) {
                    iconView.isHidden = false
                    iconView.image = image
                    iconView.contentTintColor = color
                    iconSize = model.scaled(8) + 3
                }
            }
        }
        let font = NSFont.systemFont(ofSize: model.scaled(10))
        if let url = entry.url {
            textView.isHidden = true
            metadataButton.isHidden = false
            metadataButton.configure(
                title: entry.sidebarDisplayText,
                font: font,
                color: color,
                underlined: true,
                toolTip: url.absoluteString,
                onClick: { onOpenURL(url) }
            )
        } else {
            metadataButton.isHidden = true
            textView.isHidden = false
            textView.stringValue = entry.sidebarDisplayText
            textView.font = font
            textView.textColor = color
        }
        needsLayout = true
    }

    func configureLog(
        _ log: SidebarLogEntry,
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette
    ) {
        stacked = false
        metadataButton.isHidden = true
        textView.isHidden = false
        secondTextView.isHidden = true
        iconLabel.isHidden = true
        let iconName: String
        switch log.level {
        case .info: iconName = "circle.fill"
        case .progress: iconName = "arrowtriangle.right.fill"
        case .success: iconName = "checkmark.circle.fill"
        case .warning: iconName = "exclamationmark.triangle.fill"
        case .error: iconName = "xmark.circle.fill"
        }
        let color: NSColor
        if model.isActive {
            switch log.level {
            case .info: color = palette.secondary(0.5)
            case .progress: color = palette.secondary(0.8)
            default: color = palette.secondary(0.9)
            }
        } else {
            switch log.level {
            case .info: color = .secondaryLabelColor
            case .progress: color = .systemBlue
            case .success: color = .systemGreen
            case .warning: color = .systemOrange
            case .error: color = .systemRed
            }
        }
        iconView.isHidden = false
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: iconName, pointSize: model.scaled(8), weight: nil
        )
        iconView.contentTintColor = color
        iconSize = model.scaled(8) + 4
        textView.stringValue = log.message
        textView.font = .systemFont(ofSize: model.scaled(10))
        textView.textColor = palette.secondary(0.8)
        needsLayout = true
    }

    /// Branch/dir line with width-adaptive directory candidate selection
    /// (manual ViewThatFits: longest candidate that fits wins).
    func configureBranchLine(
        _ content: BranchLineContent,
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette
    ) {
        metadataButton.isHidden = true
        textView.isHidden = false
        iconView.isHidden = true
        iconLabel.isHidden = true
        iconSize = 0
        stacked = content.stacked && content.branch != nil && !content.directoryCandidates.isEmpty
        let font = NSFont.monospacedSystemFont(ofSize: model.scaled(10), weight: .regular)
        let color = palette.secondary(0.75)
        pendingCandidates = content.directoryCandidates
        if stacked {
            textView.stringValue = content.branch ?? ""
            textView.font = font
            textView.textColor = color
            secondTextView.isHidden = false
            secondTextView.font = font
            secondTextView.textColor = color
        } else if let branch = content.branch {
            // Inline: "branch · dir" (dot only when both present).
            pendingInlineBranch = branch
            textView.font = font
            textView.textColor = color
            secondTextView.isHidden = true
        } else {
            pendingInlineBranch = nil
            textView.font = font
            textView.textColor = color
            secondTextView.isHidden = true
        }
        needsLayout = true
    }

    private var pendingCandidates: [String] = []
    private var pendingInlineBranch: String?

    private func fittingCandidate(width: CGFloat, font: NSFont) -> String {
        for candidate in pendingCandidates.dropLast() {
            let candidateWidth = (candidate as NSString).size(withAttributes: [.font: font]).width
            if ceil(candidateWidth) <= width {
                return candidate
            }
        }
        return pendingCandidates.last ?? ""
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        resolveCandidates(width: width)
        let first = metadataButton.isHidden
            ? textView.measuredHeight(width: max(10, width - iconSize))
            : ceil(metadataButton.intrinsicContentSize.height)
        let second = secondTextView.isHidden ? 0 : secondTextView.measuredHeight(width: max(10, width - iconSize)) + 1
        return first + second
    }

    private func resolveCandidates(width: CGFloat) {
        guard let font = textView.font else { return }
        let available = max(10, width - iconSize)
        if stacked {
            if !pendingCandidates.isEmpty {
                secondTextView.stringValue = fittingCandidate(width: available, font: font)
            }
        } else if let branch = pendingInlineBranch {
            let dir = pendingCandidates.isEmpty ? nil : fittingCandidate(
                width: available - ceil((branch as NSString).size(withAttributes: [.font: font]).width) - 10,
                font: font
            )
            textView.stringValue = dir.map { "\(branch) · \($0)" } ?? branch
        } else if !pendingCandidates.isEmpty {
            textView.stringValue = fittingCandidate(width: available, font: font)
        }
    }

    override func layout() {
        super.layout()
        resolveCandidates(width: bounds.width)
        var x: CGFloat = 0
        if !iconView.isHidden || !iconLabel.isHidden {
            let side = iconSize
            let icon: NSView = iconView.isHidden ? iconLabel : iconView
            icon.frame = NSRect(x: 0, y: 1, width: side, height: side)
            x = side + 4
        }
        let availableWidth = max(10, bounds.width - x)
        let firstHeight = metadataButton.isHidden
            ? textView.measuredHeight(width: availableWidth)
            : ceil(metadataButton.intrinsicContentSize.height)
        let primaryView: NSView = metadataButton.isHidden ? textView : metadataButton
        primaryView.frame = NSRect(x: x, y: 0, width: availableWidth, height: firstHeight)
        if !secondTextView.isHidden {
            let secondHeight = secondTextView.measuredHeight(width: max(10, bounds.width - x))
            secondTextView.frame = NSRect(x: x, y: firstHeight + 1, width: max(10, bounds.width - x), height: secondHeight)
        }
    }
}

/// One pull-request row: status icon + underlined title + status label.
@MainActor
final class SidebarRowPullRequestLine: NSView {
    private let iconView = SidebarRowPullRequestIconView()
    private let titleButton = SidebarRowLinkButton()
    private let titleLabel = SidebarRowTextView(lines: 1)
    private let statusLabel = SidebarRowTextView(lines: 1)
    private var lineHeight: CGFloat = 14
    private var iconSize = NSSize.zero

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(iconView)
        addSubview(titleButton)
        addSubview(titleLabel)
        addSubview(statusLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        _ display: SidebarWorkspaceSnapshotBuilder.PullRequestDisplay,
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette,
        clickable: Bool,
        onOpen: @escaping () -> Void
    ) {
        let color = model.isActive ? palette.secondary(0.75) : NSColor.secondaryLabelColor
        let font = NSFont.systemFont(ofSize: model.scaled(10), weight: .semibold)
        iconView.configure(status: display.status, color: color, fontScale: model.fontScale)
        iconSize = SidebarRowPullRequestIconView.size(status: display.status, fontScale: model.fontScale)
        let title = "\(display.label) #\(display.number)"
        titleButton.isHidden = !clickable
        titleLabel.isHidden = clickable
        if clickable {
            titleButton.configure(
                title: title, font: font, color: color, underlined: true,
                toolTip: String(localized: "sidebar.pullRequest.openTooltip", defaultValue: "Open pull request"),
                onClick: onOpen
            )
        } else {
            titleLabel.stringValue = title
            titleLabel.font = font
            titleLabel.textColor = color
        }
        let statusText: String
        switch display.status {
        case .open: statusText = String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged: statusText = String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed: statusText = String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
        statusLabel.stringValue = statusText
        statusLabel.font = font
        statusLabel.textColor = color
        alphaValue = display.isStale ? 0.5 : 1
        lineHeight = max(iconSize.height, ceil(font.ascender - font.descender + font.leading))
        needsLayout = true
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        lineHeight
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(
            x: 0, y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width, height: iconSize.height
        )
        // sidebarNaturalCellSize, never intrinsicContentSize: see the
        // extension note — a pooled truncating label laid out narrow once
        // reports the truncated width forever ("PR #4  o…").
        let statusSize = statusLabel.sidebarNaturalCellSize
        let titleX = iconSize.width + 4
        // The short status word keeps its natural width; the title absorbs
        // any shortfall (it is the long, truncatable part).
        let titleWidth = max(10, bounds.width - titleX - ceil(statusSize.width) - 8)
        let title: NSView = titleButton.isHidden ? titleLabel : titleButton
        let titleSize = titleButton.isHidden
            ? titleLabel.sidebarNaturalCellSize
            : titleButton.intrinsicContentSize
        title.frame = NSRect(
            x: titleX, y: (bounds.height - titleSize.height) / 2,
            width: min(ceil(titleSize.width), titleWidth), height: titleSize.height
        )
        statusLabel.frame = NSRect(
            x: title.frame.maxX + 4, y: (bounds.height - statusSize.height) / 2,
            width: ceil(statusSize.width), height: statusSize.height
        )
    }
}

/// Borderless underlined text-link button (PR titles, ports).
@MainActor
final class SidebarRowLinkButton: NSButton {
    private var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(execute)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        font: NSFont,
        color: NSColor,
        underlined: Bool,
        toolTip: String?,
        onClick: @escaping () -> Void
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        if underlined {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        attributedTitle = NSAttributedString(string: title, attributes: attributes)
        self.toolTip = toolTip
        self.onClick = onClick
    }

    @objc private func execute() {
        onClick?()
    }
}

