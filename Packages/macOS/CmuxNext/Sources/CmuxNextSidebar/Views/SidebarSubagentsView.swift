import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A chat row's subagents under its name (`WorkspaceRowContent.subagents`, Claude desktop's Code tab):
/// one line per subagent on a thin tree line, each a click that opens its pane beside the chat, then
/// "N more"; or one stacked line of marks and a count. Lives inside the workspace row, so it moves,
/// folds and drags with it; its lines are the row's own height (`SidebarLayoutMetrics.subagentsHeight`).
final class SidebarSubagentsView: NSView {
    /// A press on a subagent's line (its id and title), or on "N more" or the stacked line (nil).
    var onOpen: ((SidebarSubagent?) -> Void)?
    private(set) var strip: SidebarSubagentStrip?
    private let treeLine = NSView()
    /// Line views by subagent id, so a subagent's line keeps its view (and its spinner) as others come and go.
    private var lines: [String: SidebarSubagentLineView] = [:]
    private let moreLine = SidebarSubagentLineView()
    private let stackLine = SidebarSubagentStackView()
    /// The x where the row's text column starts at depth 0 and how far one level indents.
    var textX: CGFloat = 0, indent: CGFloat = 0, trailingInset: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        treeLine.wantsLayer = true
        addSubview(treeLine)
        addSubview(moreLine)
        addSubview(stackLine)
        moreLine.onPress = { [weak self] in self?.onOpen?(nil) }
        stackLine.onPress = { [weak self] in self?.onOpen?(nil) }
        setAccessibilityElement(false)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    func configure(_ strip: SidebarSubagentStrip?) {
        self.strip = strip
        isHidden = strip == nil
        let rows = strip?.mode == .rows ? strip?.rows ?? [] : []
        let keep = Set(rows.map(\.subagent.id))
        for (id, view) in lines where !keep.contains(id) {
            view.removeFromSuperview()
            lines[id] = nil
        }
        for row in rows {
            let view = lines[row.subagent.id] ?? {
                let made = SidebarSubagentLineView()
                addSubview(made)
                lines[row.subagent.id] = made
                return made
            }()
            view.configure(row.subagent)
            let subagent = row.subagent
            view.onPress = { [weak self] in self?.onOpen?(subagent) }
        }
        moreLine.isHidden = (strip?.mode != .rows) || (strip?.more ?? 0) == 0
        if let more = strip?.more, more > 0 { moreLine.configureMore(more) }
        treeLine.isHidden = rows.isEmpty
        stackLine.isHidden = strip?.mode != .stack
        if let strip, strip.mode == .stack { stackLine.configure(strip) }
        needsLayout = true
    }

    /// The lines that take a click, for the row's hit test.
    var pressable: [NSView] {
        guard !isHidden else { return [] }
        return (Array(lines.values) + [moreLine, stackLine]).filter { !$0.isHidden }
    }

    func tint() {
        treeLine.layer?.backgroundColor = Palette.separator.cgColor
        lines.values.forEach { $0.tint() }
        moreLine.tint()
        stackLine.tint()
    }

    override func layout() {
        super.layout()
        guard let strip else { return }
        let line = SidebarLayoutMetrics.standard.subagentLineHeight
        let width = bounds.width
        switch strip.mode {
        case .stack:
            stackLine.frame = NSRect(x: textX, y: 0, width: max(0, width - textX - trailingInset), height: line)
        case .rows:
            var y: CGFloat = 0
            for row in strip.rows {
                guard let view = lines[row.subagent.id] else { continue }
                let x = textX + CGFloat(row.depth) * indent
                view.frame = NSRect(x: x, y: y, width: max(0, width - x - trailingInset), height: line)
                y += line
            }
            if !moreLine.isHidden {
                let x = textX + indent
                moreLine.frame = NSRect(x: x, y: y, width: max(0, width - x - trailingInset), height: line)
                y += line
            }
            // The guide line runs down the indent from the chat's name to the last line's middle.
            let lineWidth = max(1, Metrics.lineWidth(1))
            treeLine.frame = NSRect(x: textX + indent / 2, y: 0, width: lineWidth, height: max(0, y - line / 2))
        }
    }

    // MARK: Press, debug and accessibility

    // The row's hit test answers this view for a point on it (`WorkspaceRowView.interactiveSubviews`), so the
    // press lands here and goes to the line under it; a point between lines does nothing.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch pressable.first(where: { $0.frame.contains(point) }) {
        case let line as SidebarSubagentLineView: line.onPress?()
        case let stack as SidebarSubagentStackView: stack.onPress?()
        default: break
        }
    }

    override func accessibilityChildren() -> [Any]? { pressable }
}

/// One subagent's line: a small state mark (spinner while it runs, a check when done, a cross when it
/// failed, a quiet dot when it stopped) and its title, one font weight whatever its state.
final class SidebarSubagentLineView: NSControl {
    var onPress: (() -> Void)?
    private let mark: StatusIndicatorView = { let view = StatusIndicatorView(); view.usesStatusColors = true; return view }()
    private let stoppedDot = NSView()
    private let label = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private var state: SidebarSubagent.State?
    private var tracking: NSTrackingArea?
    private var hovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        stoppedDot.wantsLayer = true
        [mark, stoppedDot, label].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    func configure(_ subagent: SidebarSubagent) {
        state = subagent.state
        let title = subagent.title ?? Strings.untitledSubagent
        label.setString(title)
        switch subagent.state {
        case .running: mark.configure(.working(progress: nil))
        case .done: mark.configure(.success)
        case .failed: mark.configure(.error)
        case .stopped: mark.configure(.idle)
        }
        mark.isHidden = subagent.state == .stopped
        stoppedDot.isHidden = subagent.state != .stopped
        setAccessibilityLabel(Strings.subagentRow(title, state: subagent.state))
        setAccessibilityIdentifier("cmux.sidebar.subagent.\(subagent.id)")
        tint()
        needsLayout = true
    }

    /// "N more": no mark, the count in the quiet ink.
    func configureMore(_ count: Int) {
        state = nil
        mark.isHidden = true
        stoppedDot.isHidden = true
        label.setString(Strings.moreSubagents(count))
        setAccessibilityLabel(Strings.moreSubagents(count))
        tint()
        needsLayout = true
    }

    func tint() {
        stoppedDot.layer?.backgroundColor = Palette.textTertiary.cgColor
        label.setColor(state == nil || state == .stopped ? Palette.textTertiary : hovered ? Palette.textPrimary : Palette.textSecondary)
    }

    override func layout() {
        super.layout()
        let side = SidebarStyle.statusGlyphSize, cy = bounds.midY
        let markShown = !mark.isHidden || !stoppedDot.isHidden
        mark.frame = NSRect(x: 0, y: cy - side / 2, width: side, height: side)
        let dot = SidebarStyle.statusDotSize * 0.75
        stoppedDot.frame = NSRect(x: (side - dot) / 2, y: cy - dot / 2, width: dot, height: dot)
        stoppedDot.layer?.cornerRadius = dot / 2
        let x = markShown ? side + Metrics.space1 + Metrics.space1 / 2 : 0
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: x, y: SidebarStyle.textY(label, centerY: cy), width: max(0, bounds.width - x), height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; tint() }
    override func mouseExited(with event: NSEvent) { hovered = false; tint() }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

/// The stacked line (Claude's sidebar-subagent-stack-status-row): the subagents' marks overlapping, then
/// what they do ("3 running", "8 done", "1 failed"), quiet like a second line.
final class SidebarSubagentStackView: NSControl {
    var onPress: (() -> Void)?
    private var marks: [DecorativeImageView] = []
    private var states: [SidebarSubagent.State] = []
    private let label = SidebarRowView.label(font: SidebarStyle.subtitleFont)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    func configure(_ strip: SidebarSubagentStrip) {
        states = strip.marks
        while marks.count < states.count {
            let view = DecorativeImageView()
            view.imageScaling = .scaleProportionallyDown
            addSubview(view, positioned: .below, relativeTo: label)
            marks.append(view)
        }
        for (index, view) in marks.enumerated() {
            view.isHidden = index >= states.count
            if index < states.count { view.image = NSImage.icon(.taskAi, size: Self.markSize) }
        }
        let text = Strings.subagentStack(strip)
        label.setString(text)
        setAccessibilityLabel(text)
        tint()
        needsLayout = true
    }

    static var markSize: CGFloat { SidebarStyle.subtitleFont.pointSize + 1 }

    func tint() {
        for (index, view) in marks.enumerated() where index < states.count {
            let tint = switch states[index] {
            case .running: Palette.accent
            case .failed: Palette.danger
            case .done, .stopped: Palette.textTertiary
            }
            view.setTint(tint)
        }
        label.setColor(Palette.textTertiary)
    }

    override func layout() {
        super.layout()
        let side = Self.markSize, cy = bounds.midY, step = side * 0.7
        var x: CGFloat = 0
        for (index, view) in marks.enumerated() where index < states.count {
            view.frame = NSRect(x: x, y: cy - side / 2, width: side, height: side)
            x += step
        }
        if !states.isEmpty { x += side - step + Metrics.space1 }
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: x, y: SidebarStyle.textY(label, centerY: cy), width: max(0, bounds.width - x), height: height)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}
