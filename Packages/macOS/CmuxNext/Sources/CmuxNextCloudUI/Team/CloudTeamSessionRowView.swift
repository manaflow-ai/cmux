import AppKit
import CmuxNextActions
import CmuxNextDesign

/// One team Cloud session in the Team section: its title, who it is assigned to and what it is
/// doing, and the follow (eye) toggle. It draws a value snapshot and runs every change through
/// the closures it was made with, never a store.
@MainActor
final class CloudTeamSessionRowView: NSView {
    /// What a row runs: the follow toggle as a catalog action, a click as an open, a right-click's menu.
    struct Actions {
        var perform: CloudTeamHostingView.Perform
        var open: @MainActor (CloudTeamSession) -> Void
        var menu: CloudTeamHostingView.RowMenu
    }

    private let actions: Actions
    private(set) var row: CloudTeamSession?
    private var members: [CloudTeamMember] = []
    private var colors: CloudTeamColors?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let eye = NSButton()
    private var hover: PointerHover?
    private var isHovered = false { didSet { if isHovered != oldValue { tint() } } }

    init(actions: Actions) {
        self.actions = actions
        super.init(frame: .zero)
        wantsLayer = true
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        title.font = Typography.body
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = Typography.caption
        subtitle.lineBreakMode = .byTruncatingTail
        eye.isBordered = false
        eye.imagePosition = .imageOnly
        eye.setButtonType(.momentaryChange)
        eye.target = self
        eye.action = #selector(toggleFollow)
        [icon, title, subtitle, eye].forEach(addSubview)
        hover = PointerHover(self) { [weak self] hovering in self?.isHovered = hovering }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    var titleText: String { title.stringValue }
    var subtitleText: String { subtitle.stringValue }
    /// Whether the row offers the follow toggle (a session assigned to the person has none).
    var showsFollow: Bool { !eye.isHidden }

    func configure(_ row: CloudTeamSession, members: [CloudTeamMember], colors: CloudTeamColors) {
        self.row = row
        self.members = members
        self.colors = colors
        icon.image = NSImage(systemSymbolName: row.kind == .chat ? "bubble.left" : "square.stack", accessibilityDescription: nil)
        title.stringValue = row.title.isEmpty ? row.session : row.title
        subtitle.stringValue = Self.subtitle(row)
        eye.isHidden = !row.canFollow
        eye.image = NSImage(systemSymbolName: row.following ? "eye.fill" : "eye", accessibilityDescription: nil)
        let follow = row.following ? CloudTeamStrings.unfollow : CloudTeamStrings.follow
        eye.themedToolTip = follow
        eye.setAccessibilityLabel(follow)
        tint()
        needsLayout = true
    }

    /// Who it is assigned to (unless that is the person) and what it is doing.
    static func subtitle(_ row: CloudTeamSession) -> String {
        let doing = CloudTeamStrings.activity(row.activity, machine: row.machineState)
        guard !row.assignedToYou else { return doing }
        return "\(CloudTeamStrings.assignedTo(row.assigneeName ?? row.assignee)) · \(doing)"
    }

    private func tint() {
        guard let row, let colors else { return }
        layer?.backgroundColor = isHovered ? colors.hover.cgColor : nil
        icon.contentTintColor = colors.secondary
        title.textColor = colors.text
        switch row.activity {
        case "needs_attention": subtitle.textColor = colors.attention
        case "working": subtitle.textColor = colors.text
        default: subtitle.textColor = colors.secondary
        }
        eye.contentTintColor = row.following ? colors.text : colors.tertiary
        // The eye shows on a followed row and under the pointer.
        eye.alphaValue = row.following || isHovered ? 1 : 0
    }

    /// Follows or unfollows the row's session, as `cmux cloud follow|unfollow` does.
    @objc func toggleFollow() {
        guard let row, row.canFollow else { return }
        actions.perform(row.following ? "cloud.team.unfollow" : "cloud.team.follow", ["session": .string(row.key)])
    }

    /// The eye takes its own clicks; the rest of the row (its labels and icon too) is the row's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return !eye.isHidden && eye.frame.contains(convert(point, from: superview)) ? eye : self
    }

    /// Taken here, so the list under it starts no press.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let row, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        actions.open(row)
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    /// The row's right-click menu (Follow, Reassign To, Copy Link, Archive); nil with no rows.
    func contextMenu() -> NSMenu? {
        guard let row, let menu = actions.menu(row, members), !menu.items.isEmpty else { return nil }
        return menu
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8, gap: CGFloat = 6
        let side = Metrics.smallIconSize
        icon.frame = NSRect(x: inset, y: (bounds.height - side) / 2, width: side, height: side)
        let eyeSide = eye.isHidden ? 0 : side
        eye.frame = NSRect(x: bounds.width - inset - eyeSide, y: (bounds.height - eyeSide) / 2, width: eyeSide, height: eyeSide)
        let x = icon.frame.maxX + gap
        let trailing = eye.isHidden ? bounds.width - inset : eye.frame.minX - gap
        let width = max(0, trailing - x)
        let titleHeight = ceil(title.intrinsicContentSize.height), subtitleHeight = ceil(subtitle.intrinsicContentSize.height)
        let top = max(0, (bounds.height - titleHeight - subtitleHeight) / 2)
        title.frame = NSRect(x: x, y: top, width: width, height: titleHeight)
        subtitle.frame = NSRect(x: x, y: top + titleHeight, width: width, height: subtitleHeight)
    }
}
