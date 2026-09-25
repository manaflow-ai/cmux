import AppKit
import CmuxSidebar
import CmuxWorkspaces

/// One pull-request row: status icon + underlined title + status label.
@MainActor
final class SidebarRowPullRequestLine: NSView {
    private let iconView = SidebarRowPullRequestIconView()
    private let checkIconView = SidebarRowPullRequestCheckIconView()
    private let titleButton = SidebarRowLinkButton()
    private let titleLabel = SidebarRowTextView(lines: 1)
    private let statusLabel = SidebarRowTextView(lines: 1)
    private var lineHeight: CGFloat = 14
    private var iconSize = NSSize.zero
    private var checkIconSize = NSSize.zero

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(iconView)
        addSubview(checkIconView)
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
        let color = palette.secondary(0.75)
        let font = NSFont.systemFont(ofSize: model.scaled(10), weight: .semibold)
        iconView.configure(status: display.status, color: color, fontScale: model.fontScale)
        iconSize = SidebarRowPullRequestIconView.size(status: display.status, fontScale: model.fontScale)
        checkIconView.configure(
            checks: display.checks,
            fallback: color,
            pointSize: model.scaled(9)
        )
        checkIconSize = display.checks == nil ? .zero : NSSize(width: model.scaled(12), height: model.scaled(12))
        let title = "\(display.label) #\(display.number)"
        titleButton.isHidden = !clickable
        titleLabel.isHidden = clickable
        if clickable {
            titleButton.configure(
                title: title, font: font, color: color, underlined: true,
                toolTip: String(format: String(localized: "sidebar.pullRequest.openTooltip", defaultValue: "Open %1$@ #%2$lld"), display.label, Int64(display.number)),
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
        let checkSize = checkIconSize
        let titleX = iconSize.width + 4
        // The short status word keeps its natural width; the title absorbs
        // any shortfall (it is the long, truncatable part).
        let checkSpace = checkSize.width > 0 ? checkSize.width + 5 : 0
        let titleWidth = max(10, bounds.width - titleX - ceil(statusSize.width) - checkSpace - 8)
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
        checkIconView.frame = NSRect(
            x: statusLabel.frame.maxX + 5,
            y: (bounds.height - checkSize.height) / 2,
            width: checkSize.width,
            height: checkSize.height
        )
    }
}
