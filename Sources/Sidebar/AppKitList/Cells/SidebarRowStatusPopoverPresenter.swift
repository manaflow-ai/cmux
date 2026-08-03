import AppKit
import CmuxWorkspaces

@MainActor
final class SidebarRowStatusPopoverPresenter: NSObject, NSPopoverDelegate {
    private let contentController = SidebarStatusPopoverViewController()
    private var popover: NSPopover?
    private var closingProgrammatically = false

    var onExternalDismiss: (() -> Void)?
    var isShown: Bool { popover?.isShown == true }

    func present(
        model: SidebarWorkspaceStatusPopoverModel,
        onSelectLane: @escaping @MainActor (WorkspaceTaskStatus?) -> Void,
        onSelectNone: @escaping @MainActor () -> Void,
        relativeTo rect: NSRect,
        of view: NSView,
        preferredEdge: NSRectEdge
    ) {
        guard view.window != nil else { return }
        let popover = self.popover ?? makePopover()
        contentController.configure(
            model: model,
            onSelectLane: onSelectLane,
            onSelectNone: onSelectNone,
            onClose: { [weak self] in self?.close() }
        )
        popover.contentSize = contentController.contentSize
        if popover.isShown { return }
        popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
    }

    func update(_ model: SidebarWorkspaceStatusPopoverModel) {
        guard let popover, popover.isShown else { return }
        contentController.update(model: model)
        popover.contentSize = contentController.contentSize
    }

    func close() {
        guard let popover, popover.isShown else { return }
        closingProgrammatically = true
        popover.performClose(nil)
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = contentController
        popover.delegate = self
        self.popover = popover
        return popover
    }

    func popoverDidShow(_ notification: Notification) {
        guard let window = contentController.view.window else { return }
        window.makeKey()
        window.makeFirstResponder(contentController.view)
    }

    func popoverDidClose(_ notification: Notification) {
        let external = !closingProgrammatically
        closingProgrammatically = false
        popover = nil
        if external { onExternalDismiss?() }
        onExternalDismiss = nil
    }
}

@MainActor
private final class SidebarStatusPopoverViewController: NSViewController {
    private let contentView = SidebarStatusPopoverView()
    private var onSelectLane: (@MainActor (WorkspaceTaskStatus?) -> Void)?
    private var onSelectNone: (@MainActor () -> Void)?
    private var onClose: (@MainActor () -> Void)?

    var contentSize: NSSize { contentView.intrinsicContentSize }

    override func loadView() {
        contentView.onActivate = { [weak self] lane in self?.activate(lane) }
        contentView.onClose = { [weak self] in self?.onClose?() }
        view = contentView
    }

    func configure(
        model: SidebarWorkspaceStatusPopoverModel,
        onSelectLane: @escaping @MainActor (WorkspaceTaskStatus?) -> Void,
        onSelectNone: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        loadViewIfNeeded()
        self.onSelectLane = onSelectLane
        self.onSelectNone = onSelectNone
        self.onClose = onClose
        contentView.update(model: model, resetsHighlight: true)
    }

    func update(model: SidebarWorkspaceStatusPopoverModel) {
        loadViewIfNeeded()
        contentView.update(model: model, resetsHighlight: false)
    }

    private func activate(_ lane: WorkspaceTodoStatusLane) {
        if lane.isNone {
            onSelectNone?()
        } else {
            onSelectLane?(lane.status)
        }
        onClose?()
    }
}

@MainActor
private final class SidebarStatusPopoverView: NSView {
    private static let width: CGFloat = 200
    private static let rowHeight: CGFloat = 30
    private static let inset: CGFloat = 6
    private static let dividerHeight: CGFloat = 7
    private static let footnoteHeight: CGFloat = 30

    private var lanes: [WorkspaceTodoStatusLane] = []
    private var highlightedIndex = 0
    private var laneControls: [SidebarStatusLaneControl] = []
    private let divider = NSBox()
    private let footnote = NSTextField(wrappingLabelWithString: String(
        localized: "sidebar.statusPopover.pinFootnote",
        defaultValue: "Pinned status clears when activity changes"
    ))
    private var showsFootnote = false

    var onActivate: ((WorkspaceTodoStatusLane) -> Void)?
    var onClose: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("SidebarWorkspaceStatusPopover")
        divider.boxType = .separator
        addSubview(divider)
        footnote.font = .systemFont(ofSize: 10)
        footnote.textColor = .secondaryLabelColor
        footnote.maximumNumberOfLines = 2
        addSubview(footnote)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let base = Self.inset * 2
            + Self.rowHeight * CGFloat(lanes.count)
            + Self.dividerHeight
        return NSSize(
            width: Self.width,
            height: base + (showsFootnote ? Self.footnoteHeight : 0)
        )
    }

    func update(model: SidebarWorkspaceStatusPopoverModel, resetsHighlight: Bool) {
        lanes = WorkspaceTodoStatusLane.lanes(
            inferred: model.inferred,
            activeOverride: model.activeOverride,
            isHidden: model.isHidden
        )
        while laneControls.count < lanes.count {
            let control = SidebarStatusLaneControl()
            control.onHighlight = { [weak self] index in self?.setHighlightedIndex(index) }
            control.onActivate = { [weak self] index in self?.activate(index) }
            addSubview(control)
            laneControls.append(control)
        }
        if resetsHighlight || !lanes.indices.contains(highlightedIndex) {
            highlightedIndex = lanes.firstIndex(where: \.isSelected) ?? 0
        }
        showsFootnote = model.activeOverride != nil
        footnote.isHidden = !showsFootnote
        for (index, lane) in lanes.enumerated() {
            laneControls[index].configure(lane: lane, index: index)
        }
        for index in lanes.count..<laneControls.count {
            laneControls[index].isHidden = true
        }
        updateHighlights()
        invalidateIntrinsicContentSize()
        frame.size = intrinsicContentSize
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y = Self.inset
        let contentWidth = bounds.width - Self.inset * 2
        for (index, control) in laneControls.prefix(lanes.count).enumerated() {
            if index == 1 {
                divider.frame = NSRect(
                    x: Self.inset,
                    y: y + (Self.dividerHeight - 1) / 2,
                    width: contentWidth,
                    height: 1
                )
                y += Self.dividerHeight
            }
            control.frame = NSRect(x: Self.inset, y: y, width: contentWidth, height: Self.rowHeight)
            y += Self.rowHeight
        }
        footnote.frame = NSRect(
            x: Self.inset + 8,
            y: y + 4,
            width: contentWidth - 16,
            height: Self.footnoteHeight - 4
        )
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126:
            moveHighlight(-1)
        case 125:
            moveHighlight(1)
        case 36, 76:
            activate(highlightedIndex)
        case 53:
            onClose?()
        default:
            let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if let index = lanes.firstIndex(where: { $0.title.lowercased().hasPrefix(typed) }),
               !typed.isEmpty {
                setHighlightedIndex(index)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func moveHighlight(_ delta: Int) {
        guard !lanes.isEmpty else { return }
        setHighlightedIndex((highlightedIndex + delta + lanes.count) % lanes.count)
    }

    private func setHighlightedIndex(_ index: Int) {
        guard lanes.indices.contains(index) else { return }
        highlightedIndex = index
        updateHighlights()
    }

    private func updateHighlights() {
        for (index, control) in laneControls.enumerated() {
            control.isKeyboardHighlighted = index == highlightedIndex
        }
    }

    private func activate(_ index: Int) {
        guard lanes.indices.contains(index) else { return }
        onActivate?(lanes[index])
    }
}

@MainActor
private final class SidebarStatusLaneControl: NSControl {
    private static let glyphScale: CGFloat = 12 / 9
    private let glyph = SidebarRowTaskStatusGlyphButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var index = 0

    var onHighlight: ((Int) -> Void)?
    var onActivate: ((Int) -> Void)?
    var isKeyboardHighlighted = false { didSet { updateBackground() } }
    private var isPointerHighlighted = false { didSet { updateBackground() } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        glyph.isEnabled = false
        addSubview(glyph)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        checkmark.image = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        checkmark.contentTintColor = .secondaryLabelColor
        addSubview(checkmark)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    func configure(lane: WorkspaceTodoStatusLane, index: Int) {
        self.index = index
        titleLabel.stringValue = lane.title
        checkmark.isHidden = !lane.isSelected
        if let status = lane.status {
            glyph.isHidden = false
            glyph.configure(
                model: .init(
                    status: status,
                    hasOverride: false,
                    usesMonochrome: false,
                    fontScale: Self.glyphScale
                ),
                monochromeColor: .labelColor,
                neutralColor: .secondaryLabelColor
            )
        } else {
            glyph.isHidden = true
        }
        setAccessibilityRole(.button)
        setAccessibilityLabel(lane.title)
        setAccessibilityIdentifier("SidebarWorkspaceStatusPopoverLane.\(lane.id)")
        isHidden = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let glyphSize = SidebarRowTaskStatusGlyphButton.occupiedSize(fontScale: Self.glyphScale)
        glyph.frame = NSRect(
            x: 2,
            y: (bounds.height - glyphSize.height) / 2,
            width: glyphSize.width,
            height: glyphSize.height
        )
        checkmark.frame = NSRect(x: bounds.width - 19, y: (bounds.height - 14) / 2, width: 14, height: 14)
        titleLabel.frame = NSRect(
            x: glyphSize.width + 5,
            y: (bounds.height - 18) / 2,
            width: max(0, checkmark.frame.minX - glyphSize.width - 10),
            height: 18
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        trackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerHighlighted = true
        onHighlight?(index)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerHighlighted = false
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onActivate?(index)
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?(index)
        return true
    }

    private func updateBackground() {
        layer?.backgroundColor = (isKeyboardHighlighted || isPointerHighlighted)
            ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
    }
}
