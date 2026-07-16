import AppKit
import CmuxSidebar
import Foundation

/// The pull-request rows under a workspace (AppKit port of the PR `ForEach`
/// in `TabItemView`, including the custom-drawn open/merged icons).
final class SidebarWorkspaceCellPullRequestsSection: NSView {
    private let column = SidebarWorkspaceCellStackFactory.vertical(spacing: 1, alignment: .width)
    private let pool = SidebarWorkspaceCellRowPool<SidebarWorkspaceCellPullRequestRowView>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ context: SidebarWorkspaceCellContext) {
        let pullRequests = context.workspace.pullRequestRows
        guard context.settings.visibleAuxiliaryDetails.showsPullRequests, !pullRequests.isEmpty else {
            isHidden = true
            return
        }
        isHidden = false
        let rows = pool.prepare(count: pullRequests.count, in: column) {
            SidebarWorkspaceCellPullRequestRowView()
        }
        for (pullRequest, row) in zip(pullRequests, rows) {
            row.update(pullRequest: pullRequest, context: context)
        }
    }
}

/// One pull-request line: status icon, underlined title, status word, and an
/// invisible full-row button when PR rows are clickable.
final class SidebarWorkspaceCellPullRequestRowView: NSView {
    private let row = SidebarWorkspaceCellStackFactory.horizontal(spacing: 4)
    private let icon = SidebarWorkspaceCellPullRequestIconView()
    private let titleLabel = SidebarWorkspaceCellLabel()
    private let statusLabel = SidebarWorkspaceCellLabel()
    private let spacer = NSView()
    private let clickButton = SidebarWorkspaceCellButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("SidebarPullRequestRow")

        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        row.addArrangedSubview(icon)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(statusLabel)
        row.addArrangedSubview(spacer)
        addSubview(row)

        clickButton.imagePosition = .noImage
        clickButton.title = ""
        addSubview(clickButton)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            clickButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            clickButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            clickButton.topAnchor.constraint(equalTo: topAnchor),
            clickButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(
        pullRequest: SidebarWorkspaceSnapshotBuilder.PullRequestDisplay,
        context: SidebarWorkspaceCellContext
    ) {
        let style = context.style
        let color = style.pullRequestForeground
        let font = SidebarWorkspaceCellFonts.system(style.fontSize(10), weight: .semibold)
        let clickable = context.settings.makesPullRequestsClickable
        let title = "\(pullRequest.label) #\(pullRequest.number)"

        icon.update(status: pullRequest.status, color: color, fontScale: style.fontScale)

        var titleAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        if clickable {
            titleAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        titleLabel.attributedStringValue = NSAttributedString(string: title, attributes: titleAttributes)

        statusLabel.font = font
        statusLabel.textColor = color
        statusLabel.stringValue = Self.statusLabelText(pullRequest.status)

        alphaValue = pullRequest.isStale ? 0.5 : 1

        clickButton.isHidden = !clickable
        clickButton.isInteractionEnabled = clickable
        if clickable {
            let url = pullRequest.url
            let actions = context.actions
            clickButton.onPress = { actions?.openPullRequest(url) }
            clickButton.toolTip = String(
                localized: "sidebar.pullRequest.openTooltip",
                defaultValue: "Open \(title)"
            )
        }
    }

    private static func statusLabelText(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open: return String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged: return String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed: return String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
    }
}

/// Custom-drawn PR status glyph. Open/merged reproduce the `Path` drawing in
/// `TabItemView.PullRequestOpenIcon` / `PullRequestMergedIcon` (13×13 design
/// space scaled by the sidebar font scale); closed uses the SF `xmark.circle`.
final class SidebarWorkspaceCellPullRequestIconView: NSView {
    private static let designSize: CGFloat = 13
    private static let closedDesignSize: CGFloat = 12
    private static let lineWidth: CGFloat = 1.2
    private static let nodeDiameter: CGFloat = 3.0

    private var status: SidebarPullRequestStatus = .open
    private var color: NSColor = .secondaryLabelColor
    private var fontScale: CGFloat = 1
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: Self.designSize)
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: Self.designSize)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint.isActive = true
        heightConstraint.isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    // The SwiftUI paths are authored in a top-left origin space.
    override var isFlipped: Bool { true }

    func update(status: SidebarPullRequestStatus, color: NSColor, fontScale: CGFloat) {
        self.status = status
        self.color = color
        self.fontScale = max(0.1, fontScale)
        let side = (status == .closed ? Self.closedDesignSize : Self.designSize) * self.fontScale
        widthConstraint.constant = side
        heightConstraint.constant = side
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let graphicsContext = NSGraphicsContext.current else { return }
        let cgContext = graphicsContext.cgContext
        cgContext.saveGState()
        defer { cgContext.restoreGState() }

        if status == .closed {
            drawClosed()
            return
        }

        cgContext.scaleBy(x: fontScale, y: fontScale)
        color.setStroke()

        let stroke = NSBezierPath()
        stroke.lineWidth = Self.lineWidth
        stroke.lineCapStyle = .round
        stroke.lineJoinStyle = .round
        switch status {
        case .open:
            stroke.move(to: NSPoint(x: 3.0, y: 4.8))
            stroke.line(to: NSPoint(x: 3.0, y: 9.2))
            stroke.move(to: NSPoint(x: 4.8, y: 3.0))
            stroke.line(to: NSPoint(x: 9.4, y: 3.0))
            stroke.line(to: NSPoint(x: 11.0, y: 4.6))
            stroke.line(to: NSPoint(x: 11.0, y: 9.2))
        case .merged:
            stroke.move(to: NSPoint(x: 4.6, y: 4.6))
            stroke.line(to: NSPoint(x: 7.1, y: 7.0))
            stroke.line(to: NSPoint(x: 9.2, y: 7.0))
            stroke.move(to: NSPoint(x: 4.6, y: 9.4))
            stroke.line(to: NSPoint(x: 7.1, y: 7.0))
        case .closed:
            break
        }
        stroke.stroke()

        let nodeCenters: [NSPoint] = status == .open
            ? [NSPoint(x: 3.0, y: 3.0), NSPoint(x: 3.0, y: 11.0), NSPoint(x: 11.0, y: 11.0)]
            : [NSPoint(x: 3.0, y: 3.0), NSPoint(x: 3.0, y: 11.0), NSPoint(x: 11.0, y: 7.0)]
        for center in nodeCenters {
            let radius = Self.nodeDiameter / 2
            let node = NSBezierPath(ovalIn: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: Self.nodeDiameter,
                height: Self.nodeDiameter
            ))
            node.lineWidth = Self.lineWidth
            node.stroke()
        }
    }

    private func drawClosed() {
        guard let image = SidebarWorkspaceCellSymbols.image(
            "xmark.circle",
            pointSize: 7 * fontScale
        ) else { return }
        let tinted = tintedImage(image, color: color)
        let origin = NSPoint(
            x: (bounds.width - tinted.size.width) / 2,
            y: (bounds.height - tinted.size.height) / 2
        )
        tinted.draw(
            in: NSRect(origin: origin, size: tinted.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private func tintedImage(_ image: NSImage, color: NSColor) -> NSImage {
        let result = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return result
    }
}
