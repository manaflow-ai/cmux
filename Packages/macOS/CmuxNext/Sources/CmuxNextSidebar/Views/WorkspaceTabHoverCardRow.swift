import AppKit
import CmuxAgentBrands
import CmuxNextDesign
import CmuxNextIcons

@MainActor
final class WorkspaceTabHoverCardRow: NSView {
    private let icon = NSImageView()
    private let title = ChromeLabel(labelWithString: "")
    private let cwd = ChromeLabel(labelWithString: "")
    private let showsFolder: Bool
    private let activity = StatusIndicatorView()
    private let textStack = NSStackView()
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { paint() } }
    var isKeyboardSelected = false { didSet { paint() } }
    var onRelease: (() -> Void)?
    private var pressed = false
    private var pressedTabID: TabID?
    private(set) var reportedLine = ""
    private var currentTabID: TabID?

    override var isFlipped: Bool { true }

    init(height: CGFloat, showsFolder: Bool) {
        self.showsFolder = showsFolder
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.itemCornerRadius
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.font = Typography.body
        title.lineBreakMode = .byTruncatingTail
        // Digits of one width, so a count that changes keeps the line still (tabular numbers).
        cwd.font = Typography.system(.monospacedDigit, size: Typography.caption.pointSize, weight: .regular)
        cwd.lineBreakMode = .byTruncatingMiddle
        for label in [title, cwd] { label.setContentCompressionResistancePriority(.required, for: .vertical) }
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(cwd)
        title.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        cwd.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        activity.tracksWindowOcclusion = true
        activity.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(textStack)
        addSubview(activity)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Metrics.iconSize),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Metrics.space2),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(equalTo: activity.leadingAnchor, constant: -Metrics.space2),
            activity.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space2),
            activity.centerYAnchor.constraint(equalTo: centerYAnchor),
            activity.widthAnchor.constraint(equalToConstant: Metrics.smallIconSize),
            activity.heightAnchor.constraint(equalToConstant: Metrics.smallIconSize),
        ])
        addTrackingArea()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ tab: SidebarTab) {
        let sameTab = currentTabID == tab.id
        currentTabID = tab.id
        if !sameTab {
            pressed = false
            pressedTabID = nil
        }
        isHovered = false
        icon.image = tab.favicon.map { NSImage(cgImage: $0.image, size: NSSize(width: Metrics.iconSize, height: Metrics.iconSize)) }
            ?? tab.brand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: Metrics.iconSize) }
            ?? NSImage.icon(tab.kind.icon, size: Metrics.iconSize)
        title.stringValue = tab.title
        // The second line: the chat's running subagents and commands, then the folder. A compact
        // row (one line tall) has no second line.
        let caption = showsFolder ? WorkspaceHoverCardWork.tabCaption(tab) : nil
        cwd.stringValue = caption ?? ""
        cwd.isHidden = caption == nil
        let status = Self.statusText(tab.state)
        // The compact card always uses the shared arc spinner for active work;
        // a user's pulsing-dot preference must not turn this status into a dot.
        // Working-look preferences may restyle `.working` into a breathing dot;
        // use its progress as loading so this surface always shows an arc.
        activity.configure(tab.state.isWorking ? .busy(progress: tab.state.progress) : tab.state, style: .arc)
        let work = WorkspaceHoverCardWork.counts(subagents: tab.subagentsRunning, commands: tab.commandsRunning)
        reportedLine = [tab.title, tab.folder, work, status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        setAccessibilityLabel([tab.title, work, status].compactMap { $0 }.joined(separator: ", "))
        paint()
    }

    func applyColors() {
        performWithTheme {
            title.textColor = Palette.textPrimary
            // Secondary, the token the card's facts use: tertiary washed the paths out on dark glass.
            cwd.textColor = Palette.textSecondary
            icon.contentTintColor = Palette.textSecondary
        }
        paint()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addTrackingArea()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        pressedTabID = currentTabID
        paint()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func accessibilityPerformPress() -> Bool { onRelease?(); return onRelease != nil }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false; paint() }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)), pressedTabID == currentTabID else { return }
        onRelease?()
    }

    private func addTrackingArea() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func paint() {
        performWithTheme {
            let fill = pressed || isKeyboardSelected ? Palette.pressedFill : (isHovered ? Palette.hoverFill : .clear)
            if let layer { ChromeHover.paint(layer, fill, animated: false) }
        }
    }

    private static func statusText(_ state: StatusIndicatorState) -> String {
        if case .paused = state { return Strings.activityPaused }
        if state.isWorking || state.isLoading { return Strings.priorityWorking }
        return Strings.activity(state) ?? Strings.activityDone
    }
}
