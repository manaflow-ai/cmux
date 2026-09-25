import AppKit

@MainActor
final class SurfacePipOverlayContainerView: NSView {
    private enum DragMode {
        case move
        case resize
    }

    private static let grabBarHeight: CGFloat = 24
    private static let resizeHandleSize: CGFloat = 20
    private static let buttonSize: CGFloat = 20
    private static let horizontalInset: CGFloat = 8

    let contentView = NSView(frame: .zero)
    var onMoveDelta: ((NSSize) -> Void)?
    var onResizeDelta: ((NSSize) -> Void)?
    var onInteractionEnded: (() -> Void)?
    var onRequestFocus: (() -> Void)?
    var onRequestReturn: (() -> Void)?

    private let grabBarView = NSVisualEffectView(frame: .zero)
    private let titleField = NSTextField(labelWithString: "")
    private let returnButton = NSButton(frame: .zero)
    private let resizeHandleView = NSView(frame: .zero)
    private var dragMode: DragMode?
    private var lastDragLocationInWindow: NSPoint?

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        identifier = NSUserInterfaceItemIdentifier("cmux.surfacePip.overlay.container")

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(contentView)

        grabBarView.material = .hudWindow
        grabBarView.blendingMode = .withinWindow
        grabBarView.state = .active
        addSubview(grabBarView)

        titleField.stringValue = title
        titleField.lineBreakMode = .byTruncatingTail
        titleField.textColor = .labelColor
        titleField.font = .systemFont(ofSize: 11, weight: .medium)
        grabBarView.addSubview(titleField)

        let returnDescription = String(localized: "surfacePip.returnButton.accessibilityLabel", defaultValue: "Return from Picture in Picture")
        returnButton.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: returnDescription)
        returnButton.bezelStyle = .texturedRounded
        returnButton.isBordered = false
        returnButton.target = self
        returnButton.action = #selector(returnButtonPressed(_:))
        returnButton.toolTip = returnDescription
        returnButton.setAccessibilityLabel(returnDescription)
        grabBarView.addSubview(returnButton)

        resizeHandleView.wantsLayer = true
        resizeHandleView.layer?.cornerRadius = 4
        resizeHandleView.layer?.borderWidth = 1
        resizeHandleView.layer?.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55).cgColor
        resizeHandleView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.18).cgColor
        addSubview(resizeHandleView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        let grabBarHeight = Self.grabBarHeight
        grabBarView.frame = NSRect(
            x: bounds.minX,
            y: bounds.maxY - grabBarHeight,
            width: bounds.width,
            height: grabBarHeight
        )
        contentView.frame = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: max(0, bounds.height - grabBarHeight)
        )
        returnButton.frame = NSRect(
            x: grabBarView.bounds.maxX - Self.horizontalInset - Self.buttonSize,
            y: (grabBarView.bounds.height - Self.buttonSize) / 2,
            width: Self.buttonSize,
            height: Self.buttonSize
        )
        titleField.frame = NSRect(
            x: Self.horizontalInset,
            y: 2,
            width: max(0, returnButton.frame.minX - Self.horizontalInset * 2),
            height: grabBarView.bounds.height - 4
        )
        resizeHandleView.frame = NSRect(
            x: bounds.maxX - Self.resizeHandleSize,
            y: bounds.minY,
            width: Self.resizeHandleSize,
            height: Self.resizeHandleSize
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        if resizeHandleView.frame.contains(point) { return self }
        if grabBarView.frame.contains(point) {
            let pointInGrabBar = grabBarView.convert(point, from: self)
            if returnButton.frame.contains(pointInGrabBar) {
                return returnButton
            }
            return self
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onRequestFocus?()
        lastDragLocationInWindow = event.locationInWindow
        let point = convert(event.locationInWindow, from: nil)
        dragMode = resizeHandleView.frame.contains(point) ? .resize : .move
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragMode, let lastDragLocationInWindow else { return }
        let nextLocation = event.locationInWindow
        let delta = NSSize(
            width: nextLocation.x - lastDragLocationInWindow.x,
            height: nextLocation.y - lastDragLocationInWindow.y
        )
        self.lastDragLocationInWindow = nextLocation
        switch dragMode {
        case .move:
            onMoveDelta?(delta)
        case .resize:
            onResizeDelta?(delta)
        }
    }

    override func mouseUp(with event: NSEvent) {
        _ = event
        dragMode = nil
        lastDragLocationInWindow = nil
        onInteractionEnded?()
    }

    @objc private func returnButtonPressed(_ sender: Any?) {
        _ = sender
        onRequestReturn?()
    }
}
