// SPDX-License-Identifier: GPL-3.0-or-later
public import AppKit
public import AVFoundation
import CmuxNextDesign
import CoreImage
import QuartzCore

/// The live thumbnail: the stream's layer under the window-like corners, controls that fade in on
/// hover over a blurred backdrop (Expand, Show Window, Hide), a drag that snaps to a corner, and a
/// resize grip. It never becomes first responder, so the person's typing stays where it is.
@MainActor
public final class ComputerUsePreviewThumbnail: NSView {
    public var onRequest: (ComputerUsePreviewRequest) -> Void = { _ in }
    /// The picture's aspect (width / height); the controller sets it from the stream's status.
    public var aspect: CGFloat = 16.0 / 10.0

    private let picture = ComputerUsePreviewPictureView(cornerRadius: ComputerUsePreviewLayout.cornerRadius)
    /// Its surface is an agent's terminal: Hide names the agent, not the chat.
    public var surfaceIsTerminal = false
    /// The hover controls over the picture blurred and dimmed under them (the video itself, not a
    /// glass material: it is part of the picture, as the reference shows).
    private let controls = NSView()
    private let grip = NSView()
    private var tracking: NSTrackingArea?
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    private var resizeStart: (mouse: CGPoint, side: CGFloat)?
    private var dragged = false
    /// A drag moves it now: the overlay leaves its frame alone until it snaps.
    public var isDragging: Bool { dragged && dragStart != nil }
    /// The long side while a resize drags (the controller keeps the chosen one).
    public var longSide = ComputerUsePreviewLayout.defaultLongSide
    /// The corner it docks in (the grip sits at the opposite one).
    public var corner = ComputerUsePreviewLayout.Corner.topRight { didSet { needsLayout = true } }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        addSubview(picture)
        setUpControls()
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(ComputerUsePreviewText.thumbnailLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shows `layer` (the stream's video) in the thumbnail; nil takes it out (the expanded view has it).
    public func attach(video layer: AVSampleBufferDisplayLayer?) { picture.attach(video: layer) }

    /// Shows a still in place of the video (nil: the video shows).
    public func show(still image: CGImage?) { picture.show(still: image) }

    /// A still is shown (tests).
    var showsStill: Bool { picture.showsStill }

    public override func layout() {
        super.layout()
        picture.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: ComputerUsePreviewLayout.cornerRadius,
                                   cornerHeight: ComputerUsePreviewLayout.cornerRadius, transform: nil)
        controls.frame = bounds
        let side: CGFloat = 12
        let x = corner == .topRight || corner == .bottomRight ? 0 : bounds.width - side
        let y = corner == .topRight || corner == .topLeft ? 0 : bounds.height - side
        grip.frame = NSRect(x: x, y: y, width: side, height: side)
    }

    // MARK: Entrance and exit (Motion.overlays; one frame with animations off)

    /// The entrance: scale 0.72 to 1 on a spring, a fade in and an 18 px blur clearing, as
    /// ChatGPT's preview appears.
    public func playEntrance() {
        guard let layer else { return }
        let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 0])
        blur?.name = "blur"
        layer.filters = blur.map { [$0] }
        let centered = CATransform3DIdentity
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        _ = Motion.overlays.set(layer, "transform", to: NSValue(caTransform3D: centered), spring: .popover,
                                from: NSValue(caTransform3D: CATransform3DMakeScale(ComputerUsePreviewLayout.entranceScale,
                                                                                    ComputerUsePreviewLayout.entranceScale, 1)))
        _ = Motion.overlays.set(layer, "opacity", to: 1, fade: .fadeIn, from: 0)
        _ = Motion.overlays.set(layer, "filters.blur.inputRadius", to: 0, fade: .fadeIn, from: ComputerUsePreviewLayout.entranceBlur)
    }

    /// The agent finished or stopped: a short completion pulse, then it fades away.
    public func playCompletion(_ done: @escaping @MainActor @Sendable () -> Void) {
        guard let layer else { return done() }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        _ = Motion.overlays.set(layer, "transform", to: NSValue(caTransform3D: CATransform3DMakeScale(0.94, 0.94, 1)),
                                spring: .popoverClose, from: NSValue(caTransform3D: CATransform3DMakeScale(1.04, 1.04, 1)))
        Motion.overlays.animate(.fadeOut, in: self, { self.animator().alphaValue = 0 }, completion: done)
    }

    // MARK: Controls

    private func setUpControls() {
        controls.wantsLayer = true
        controls.layerUsesCoreImageFilters = true
        controls.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        controls.layer?.backgroundFilters = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 6]).map { [$0] }
        controls.layer?.cornerRadius = ComputerUsePreviewLayout.cornerRadius
        controls.layer?.cornerCurve = .continuous
        controls.layer?.masksToBounds = true
        controls.alphaValue = 0
        let expand = button(symbol: "arrow.up.left.and.arrow.down.right", label: ComputerUsePreviewText.expand) { [weak self] in
            self?.onRequest(.expand)
        }
        let show = button(symbol: "macwindow", label: ComputerUsePreviewText.showWindow) { [weak self] in
            self?.onRequest(.showWindow)
        }
        let hide = button(symbol: "eye.slash", label: ComputerUsePreviewText.hide) { [weak self] in self?.showHideMenu() }
        let stack = NSStackView(views: [expand, show, hide])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
        ])
        addSubview(controls)
        grip.wantsLayer = true
        grip.alphaValue = 0
        addSubview(grip)
    }

    private func button(symbol: String, label: String, action: @escaping @MainActor () -> Void) -> NSButton {
        let button = PreviewControlButton(action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.body, weight: TypeScale.emphasis)
        button.contentTintColor = .white
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.refusesFirstResponder = true
        return button
    }

    private func showHideMenu() {
        let menu = NSMenu()
        let here = surfaceIsTerminal ? ComputerUsePreviewText.hideHereAgent : ComputerUsePreviewText.hideHere
        menu.addItem(PreviewMenuItem(title: here) { [weak self] in self?.onRequest(.hideHere) })
        menu.addItem(PreviewMenuItem(title: ComputerUsePreviewText.hideEverywhere) { [weak self] in self?.onRequest(.hideEverywhere) })
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseEntered(with event: NSEvent) { setControls(visible: true) }
    public override func mouseExited(with event: NSEvent) { setControls(visible: false) }

    private func setControls(visible: Bool) {
        Motion.overlays.animate(visible ? .fadeIn : .fadeOut, in: self, {
            self.controls.animator().alphaValue = visible ? 1 : 0
            self.grip.animator().alphaValue = visible ? 1 : 0
        })
    }

    // MARK: Click, drag and resize

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragged = false
        if grip.frame.insetBy(dx: -4, dy: -4).contains(point) {
            resizeStart = (event.locationInWindow, longSide)
        } else {
            dragStart = (event.locationInWindow, frame.origin)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if let resizeStart {
            let dx = event.locationInWindow.x - resizeStart.mouse.x
            let grows: CGFloat = corner == .topRight || corner == .bottomRight ? -1 : 1
            longSide = min(max(resizeStart.side + grows * dx, ComputerUsePreviewLayout.minimumLongSide), ComputerUsePreviewLayout.maximumLongSide)
            dragged = true
            onRequest(.resizing(longSide))
            return
        }
        guard let dragStart else { return }
        let dx = event.locationInWindow.x - dragStart.mouse.x, dy = event.locationInWindow.y - dragStart.mouse.y
        if abs(dx) + abs(dy) > 3 { dragged = true }
        guard dragged else { return }
        setFrameOrigin(NSPoint(x: dragStart.origin.x + dx, y: dragStart.origin.y + dy))
    }

    public override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            resizeStart = nil
        }
        if resizeStart != nil {
            if dragged { onRequest(.resized(longSide)) } // the stream's size follows once, at the end
            return
        }
        guard dragged, let superview else { return onRequest(.expand) }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        onRequest(.moved(ComputerUsePreviewLayout.Corner.nearest(to: center, in: superview.bounds.size)))
    }
}

/// A borderless control button whose click runs a closure and never takes the keyboard.
@MainActor
private final class PreviewControlButton: NSButton {
    private let run: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        run = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func clicked() { run() }
}

/// A menu item whose choice runs a closure (AppKit calls menu actions on the main thread).
private nonisolated final class PreviewMenuItem: NSMenuItem {
    private let run: (@MainActor @Sendable () -> Void)?

    init(title: String, run: @escaping @MainActor @Sendable () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(chosen), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        run = nil
        super.init(coder: coder)
    }

    @objc private func chosen() {
        guard Thread.isMainThread, let run else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { run() } // main-proof: guarded by Thread.isMainThread above
    }
}
