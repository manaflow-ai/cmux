import AppKit
import CmuxAgentBrands
import CmuxNextDesign
import CmuxNextIcons

/// One chat in the Priority view: the title and its project or machine tag on the first line with
/// the state chip at the right, then up to two lines of its latest message. The pointer over the
/// row swaps the chip for its actions (mark read, pin, snooze, archive); a click opens the chat, and
/// a press that moves past the sidebar's drag threshold drags the row instead (`onDrag`). The
/// buttons and the right-click menu run the same registered actions (the App maps them).
final class SidebarPriorityRowView: NSView {
    private(set) var entry: SidebarPriorityEntry
    var onAction: ((SidebarPriorityAction) -> Void)?
    /// The row is dragged: how far the pointer moved down since the press (up is negative), and
    /// whether it was released there.
    var onDrag: ((SidebarPriorityRowView, _ offset: CGFloat, _ ended: Bool) -> Void)?
    /// Where the press went down (window points), and whether it has moved far enough to drag.
    private var pressStart: NSPoint?
    private var dragging = false

    private let title = ChromeLabel(labelWithString: "")
    private let agentIcon = DecorativeImageView()
    /// The harness has a registered mark, drawn in the text colour; else the stable fallback colour tints the glyph.
    private var hasBrandMark = false
    private let placeLabel = ChromeLabel(labelWithString: "")
    private let preview = ChromeLabel(wrappingLabelWithString: "")
    private let chip = ChromeLabel(labelWithString: "")
    private let indicator = StatusIndicatorView()
    private let unreadDot = CALayer()
    private let markRead = SidebarIconButton(symbol: "checkmark.circle", label: Strings.priorityMarkRead)
    private let pin = SidebarIconButton(symbol: "pin", label: Strings.priorityPin)
    private let snooze = SidebarIconButton(symbol: "moon.zzz", label: Strings.prioritySnooze)
    private let archive = SidebarIconButton(symbol: "archivebox", label: Strings.priorityArchive)
    private var actionButtons: [SidebarIconButton] { [markRead, pin, snooze, archive] }
    private var pointerHover: PointerHover?
    private var isHovered = false { didSet { if isHovered != oldValue { needsLayout = true; needsDisplay = true } } }

    init(entry: SidebarPriorityEntry) {
        self.entry = entry
        super.init(frame: .zero)
        wantsLayer = true
        title.lineBreakMode = .byTruncatingTail
        placeLabel.lineBreakMode = .byTruncatingTail
        preview.maximumNumberOfLines = 2
        preview.truncatesLastVisibleLine = true
        [agentIcon, title, placeLabel, preview, chip, indicator].forEach(addSubview)
        layer?.addSublayer(unreadDot)
        for button in actionButtons { addSubview(button) }
        markRead.onPress = { [weak self] in self.map { $0.onAction?(.markRead($0.entry.id)) } }
        pin.onPress = { [weak self] in self.map { $0.onAction?(.togglePin($0.entry.id)) } }
        snooze.onPress = { [weak self] in self.map { $0.onAction?(.snooze($0.entry.id)) } }
        archive.onPress = { [weak self] in self.map { $0.onAction?(.archive($0.entry.id)) } }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        pointerHover = PointerHover(self) { [weak self] hovering in self?.isHovered = hovering }
        configure(entry)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Route row presses to this view so dragging works when the pointer starts over the title,
    /// preview, chip, or status subviews. Action buttons keep their own hit targets.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // FlippedDocument forwards its document-space point directly to each child. Convert it
        // into this row's coordinates before checking bounds and button frames; otherwise only the
        // first row (whose origin is zero) receives hits.
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return nil }
        for button in actionButtons where !button.isHidden && button.frame.contains(local) {
            return button.hitTest(convert(local, to: button)) ?? button
        }
        return self
    }

    func configure(_ entry: SidebarPriorityEntry) {
        self.entry = entry
        title.stringValue = entry.title
        let markSize = SidebarStyle.kindGlyphSize
        let brandMark = entry.brand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: markSize) }
        hasBrandMark = brandMark != nil
        agentIcon.image = brandMark ?? NSImage.icon(symbol: "person.crop.circle", size: markSize)
        placeLabel.stringValue = [entry.project, entry.machine].compactMap(\.self).joined(separator: " · ")
        preview.stringValue = entry.preview ?? ""
        preview.isHidden = entry.preview == nil
        chip.stringValue = Self.visibleChipText(entry.state, now: Date())
        indicator.configure(Self.indicatorState(entry.state))
        pin.label = entry.pinTitle
        markRead.isEnabled = entry.canMarkRead
        setAccessibilityLabel([entry.title, Self.chipText(entry.state, now: Date()), entry.preview].compactMap(\.self).joined(separator: ", "))
        needsLayout = true
        needsDisplay = true
    }

    /// Refreshes a working chip's elapsed time.
    func tick(now: Date) {
        guard case .working = entry.state else { return }
        chip.stringValue = Self.visibleChipText(entry.state, now: now)
        needsLayout = true
    }

    static func chipText(_ state: SidebarPriorityEntry.State, now: Date) -> String {
        switch state {
        case .needsYou: Strings.priorityNeedsYou
        case .done: Strings.priorityDone
        case .failed: Strings.priorityFailed
        case .lost: Strings.priorityLost
        case .ciFailing: Strings.priorityCIFailing
        case .working(let since):
            since.flatMap { elapsed(from: $0, to: now) }.map(Strings.priorityWorking(for:)) ?? Strings.priorityWorking
        case .idle: Strings.priorityIdle
        }
    }

    /// Visible status text is limited to a working duration; the indicator carries the routine
    /// state, so every row does not repeat a status word beside its harness icon.
    static func visibleChipText(_ state: SidebarPriorityEntry.State, now: Date) -> String {
        guard case .working(let since) = state else { return "" }
        return since.flatMap { elapsed(from: $0, to: now) } ?? ""
    }

    /// "5m", "2h": the largest whole unit, nil under a minute.
    static func elapsed(from start: Date, to now: Date) -> String? {
        let seconds = now.timeIntervalSince(start)
        guard seconds >= 60 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.minute, .hour, .day]
        return formatter.string(from: seconds)
    }

    /// Attention for needs you, danger for failed, lost or Red CI, dim otherwise; workspace rows use it too.
    static func chipColor(_ state: SidebarPriorityEntry.State) -> NSColor {
        switch state {
        case .needsYou: Palette.attention
        case .failed, .lost, .ciFailing: Palette.danger
        case .done, .working, .idle: Palette.textTertiary
        }
    }

    static func indicatorState(_ state: SidebarPriorityEntry.State) -> StatusIndicatorState {
        switch state {
        case .needsYou: .waiting
        case .working: .working
        case .failed, .lost, .ciFailing: .error
        case .done, .idle: .idle
        }
    }

    /// The row's height at the current type sizes: padding, the title line, and two preview lines.
    static func height(hasPreview: Bool) -> CGFloat {
        let titleLine = ceil(SidebarStyle.titleFont.boundingRectForFont.height)
        let previewLines = hasPreview ? ceil(SidebarStyle.subtitleFont.boundingRectForFont.height) * 2 + Metrics.space1 : 0
        return Metrics.space2 * 2 + titleLine + previewLines
    }

    override func layout() {
        super.layout()
        let b = bounds, inset = SidebarStyle.horizontalInset, pad = Metrics.space2
        title.font = SidebarStyle.titleFont
        placeLabel.font = SidebarStyle.titleFont
        preview.font = SidebarStyle.subtitleFont
        chip.font = SidebarStyle.subtitleFont
        let lineHeight = ceil(SidebarStyle.titleFont.boundingRectForFont.height)
        // The sidebar's one icon and text columns (SidebarStyle), not a local inset.
        let iconSide = SidebarStyle.kindGlyphSize
        let textInset = SidebarStyle.leadingTextX(leading: inset)
        agentIcon.frame = NSRect(x: SidebarStyle.iconColumnCenterX(leading: inset) - iconSide / 2,
                                 y: pad + (lineHeight - iconSide) / 2, width: iconSide, height: iconSide)
        var trailing = b.width - inset
        // The pointer over the row shows its actions in the chip's place.
        let button = lineHeight
        for (index, view) in actionButtons.reversed().enumerated() {
            view.isHidden = !isHovered
            view.frame = NSRect(x: trailing - CGFloat(index + 1) * button, y: pad, width: button, height: button)
        }
        chip.isHidden = isHovered || chip.stringValue.isEmpty
        indicator.isHidden = isHovered || !indicator.state.isVisible
        unreadDot.isHidden = isHovered || !entry.unread
        if isHovered {
            trailing -= CGFloat(actionButtons.count) * button + Metrics.space1
        } else {
            let chipSize = chip.naturalSize
            chip.frame = NSRect(x: trailing - chipSize.width, y: pad + (lineHeight - chipSize.height) / 2,
                                width: chipSize.width, height: chipSize.height)
            trailing = chip.frame.minX - Metrics.space1
            let mark = SidebarStyle.indicatorSize
            if indicator.state.isVisible {
                indicator.frame = NSRect(x: trailing - mark, y: pad + (lineHeight - mark) / 2, width: mark, height: mark)
                trailing = indicator.frame.minX - Metrics.space1
            }
            let dot = SidebarStyle.unreadDotSize
            unreadDot.frame = CGRect(x: trailing - dot, y: pad + (lineHeight - dot) / 2, width: dot, height: dot)
            unreadDot.cornerRadius = dot / 2
            if entry.unread { trailing = unreadDot.frame.minX - Metrics.space1 }
        }
        let textWidth = max(0, trailing - textInset)
        let tagWidth = placeLabel.stringValue.isEmpty ? 0 : min(placeLabel.naturalSize.width, textWidth * 0.4)
        let titleWidth = min(title.naturalSize.width, textWidth - tagWidth - (tagWidth > 0 ? Metrics.space2 : 0))
        title.frame = NSRect(x: textInset, y: pad, width: max(0, titleWidth), height: lineHeight)
        placeLabel.frame = NSRect(x: title.frame.maxX + Metrics.space2, y: pad, width: tagWidth, height: lineHeight)
        let previewTop = pad + lineHeight + Metrics.space1
        // The full row's lines, not the bounds': an opening or closing slot clips them, never squeezes them.
        let fullHeight = Self.height(hasPreview: entry.preview != nil)
        preview.frame = NSRect(x: textInset, y: previewTop, width: max(0, b.width - inset - textInset), height: max(0, fullHeight - previewTop - pad))
    }

    override func updateLayer() {
        performWithTheme {
            title.textColor = Palette.textPrimary
            agentIcon.contentTintColor = hasBrandMark ? Palette.textPrimary
                : entry.agentColor.map(SidebarStyle.color) ?? Palette.textSecondary
            placeLabel.textColor = entry.machine.map(Self.machineColor) ?? Palette.textTertiary
            preview.textColor = Palette.textSecondary
            chip.textColor = Self.chipColor(entry.state)
            unreadDot.backgroundColor = Palette.notificationBlue.cgColor
            if let layer {
                layer.cornerRadius = SidebarStyle.rowCornerRadius
                ChromeHover.paint(layer, isHovered ? Palette.hoverFill : nil, animated: window != nil)
            }
        }
    }

    /// A machine's tag takes a stable color of the group palette, so one machine reads the same in every row.
    static func machineColor(_ machine: String) -> NSColor {
        let colors = GroupColor.allCases.filter { $0 != .grey }
        let sum = machine.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return SidebarStyle.color(colors[sum % colors.count])
    }

    override func mouseDown(with event: NSEvent) {
        pressStart = event.locationInWindow
        dragging = false
    }

    /// Past the threshold (a click's jitter never drags, as in the main list) the press drags the row.
    override func mouseDragged(with event: NSEvent) {
        guard let start = pressStart else { return }
        let point = event.locationInWindow
        if !dragging { dragging = SidebarPress.movedPastThreshold(from: start, to: point) }
        if dragging { onDrag?(self, start.y - point.y, false) }
    }

    /// The App's menu for the row's chat (`SidebarContextTarget.priorityChat`): the same actions as
    /// the hover buttons.
    override func menu(for event: NSEvent) -> NSMenu? {
        let sidebar = sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? SidebarView }.first
        return sidebar?.contextMenuProvider?(.priorityChat(entry.id))
    }

    override func mouseUp(with event: NSEvent) {
        let start = pressStart, dragged = dragging
        pressStart = nil
        dragging = false
        if dragged, let start {
            onDrag?(self, start.y - event.locationInWindow.y, true)
            return
        }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onAction?(.open(entry.id))
    }

    override func accessibilityPerformPress() -> Bool {
        onAction?(.open(entry.id))
        return true
    }
}
