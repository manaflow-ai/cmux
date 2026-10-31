import AppKit
import CmuxAgentBrands
import CmuxNextDesign
import CmuxNextIcons

/// The compact Rex-style workspace card: the workspace title followed by one
/// selectable row per inner tab. The panel is intentionally small and quiet;
/// the existing detail card remains available through its setting toggle.
@MainActor
final class WorkspaceTabHoverCardView: NSView, HoverCardInteractiveBody, HoverCardTextReporting {
    static let cardWidth: CGFloat = 292
    private static let padding = Metrics.space4
    private let rowHeight: CGFloat

    private let titleLabel = ChromeLabel(labelWithString: "")
    private let scrollView = NSScrollView()
    private let document = WorkspaceTabHoverDocument()
    private var listHeight: NSLayoutConstraint?
    private var rowViews: [WorkspaceTabHoverCardRow] = []
    private var tabs: [SidebarTab] = []
    private var selectedIndex = 0
    private var showsKeyboardSelection = false
    var onSelect: ((TabID) -> Void)?

    var reportedLines: [String] {
        [titleLabel.stringValue] + rowViews.prefix(tabs.count).map { $0.reportedLine }
    }

    override var isFlipped: Bool { true }

    init(rowHeight: CGFloat = 42) {
        self.rowHeight = rowHeight
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.font = Typography.bodyEmphasized
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.verticalScrollElasticity = .none
        SystemScrollers.followThin(scrollView)
        for view in [titleLabel, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.cardWidth),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Metrics.space2),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
        ])
        let height = scrollView.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        listHeight = height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, tabs: [SidebarTab]) {
        let changed = self.tabs.map(\.id) != tabs.map(\.id)
        let selected = self.tabs.indices.contains(selectedIndex) ? self.tabs[selectedIndex].id : nil
        self.tabs = tabs
        titleLabel.stringValue = title
        selectedIndex = selected.flatMap { id in tabs.firstIndex { $0.id == id } } ?? 0
        while rowViews.count < tabs.count {
            let row = WorkspaceTabHoverCardRow(height: rowHeight)
            row.onRelease = { [weak self, weak row] in
                guard let self, let row, let index = self.rowViews.firstIndex(where: { $0 === row }),
                      index < self.tabs.count else { return }
                self.selectedIndex = index
                self.updateSelection()
                self.onSelect?(self.tabs[index].id)
            }
            document.addSubview(row)
            rowViews.append(row)
        }
        for index in rowViews.indices {
            let shown = index < tabs.count
            rowViews[index].isHidden = !shown
            if shown {
                rowViews[index].configure(tabs[index])
                rowViews[index].frame = CGRect(x: 0, y: CGFloat(index) * (rowHeight + Metrics.space1),
                                              width: Self.cardWidth - 2 * Self.padding, height: rowHeight)
            }
        }
        let height = max(0, CGFloat(tabs.count) * (rowHeight + Metrics.space1) - Metrics.space1)
        document.frame = CGRect(x: 0, y: 0, width: Self.cardWidth - 2 * Self.padding, height: height)
        listHeight?.constant = min(height, 320)
        if changed { scrollView.contentView.scroll(to: .zero); showsKeyboardSelection = false }
        updateSelection()
        applyColors()
    }

    func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            rowViews.forEach { $0.applyColors() }
        }
        updateSelection()
    }

    func handleHoverCardKeyDown(_ event: NSEvent) -> Bool {
        guard !tabs.isEmpty, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 125: moveSelection(by: 1) // down
        case 126: moveSelection(by: -1) // up
        case 36, 76: onSelect?(tabs[selectedIndex].id) // return / keypad enter
        default: return false
        }
        return true
    }

    private func moveSelection(by delta: Int) {
        showsKeyboardSelection = true
        selectedIndex = (selectedIndex + delta + tabs.count) % tabs.count
        updateSelection()
        rowViews[selectedIndex].scrollToVisible(rowViews[selectedIndex].bounds)
    }

    private func updateSelection() {
        for (index, row) in rowViews.enumerated() where index < tabs.count {
            row.isKeyboardSelected = showsKeyboardSelection && index == selectedIndex
        }
    }
}

private final class WorkspaceTabHoverDocument: NSView {
    override var isFlipped: Bool { true }
}

extension WorkspaceTabHoverCardView {
    /// What a row's status indicator draws for `state`. The compact card always uses the shared
    /// arc spinner for active work: working-look preferences may restyle `.working` into a
    /// breathing dot, so its progress is drawn as loading. Every other state (loading, waiting,
    /// error, done) keeps its own glyph beside its status word.
    nonisolated static func indicatorState(for state: StatusIndicatorState) -> StatusIndicatorState {
        state.isWorking ? .busy(progress: state.progress) : state
    }
}

@MainActor
private final class WorkspaceTabHoverCardRow: NSView {
    private let icon = NSImageView()
    private let title = ChromeLabel(labelWithString: "")
    private let cwd = ChromeLabel(labelWithString: "")
    private let status = ChromeLabel(labelWithString: "")
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

    init(height: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.itemCornerRadius
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.font = Typography.body
        title.lineBreakMode = .byTruncatingTail
        cwd.font = Typography.caption
        cwd.lineBreakMode = .byTruncatingMiddle
        status.font = Typography.caption
        status.alignment = .right
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        for label in [title, cwd, status] { label.setContentCompressionResistancePriority(.required, for: .vertical) }
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
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(textStack)
        addSubview(activity)
        addSubview(status)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Metrics.iconSize),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Metrics.space2),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(equalTo: activity.leadingAnchor, constant: -Metrics.space2),
            activity.trailingAnchor.constraint(equalTo: status.leadingAnchor, constant: -Metrics.space1),
            activity.centerYAnchor.constraint(equalTo: centerYAnchor),
            activity.widthAnchor.constraint(equalToConstant: Metrics.smallIconSize),
            activity.heightAnchor.constraint(equalToConstant: Metrics.smallIconSize),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space2),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
        addTrackingArea()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ tab: SidebarTab) {
        currentTabID = tab.id
        pressed = false
        pressedTabID = nil
        icon.image = tab.favicon.map { NSImage(cgImage: $0.image, size: NSSize(width: Metrics.iconSize, height: Metrics.iconSize)) }
            ?? tab.brand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: Metrics.iconSize) }
            ?? NSImage.icon(tab.kind.icon, size: Metrics.iconSize)
        title.stringValue = tab.title
        cwd.stringValue = tab.folder ?? ""
        cwd.isHidden = tab.folder == nil || tab.folder?.isEmpty == true
        status.stringValue = Self.statusText(tab.state)
        activity.configure(WorkspaceTabHoverCardView.indicatorState(for: tab.state), style: .arc)
        setAccessibilityLabel("\(tab.title), \(status.stringValue)")
        reportedLine = [tab.title, tab.folder, status.stringValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        paint()
    }

    func applyColors() {
        performWithTheme {
            title.textColor = Palette.textPrimary
            // Secondary, as the rich card's facts: tertiary washed the paths out on dark glass (#24785).
            cwd.textColor = Palette.textSecondary
            status.textColor = Palette.textSecondary
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
