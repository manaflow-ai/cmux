// SPDX-License-Identifier: GPL-3.0-or-later
public import AppKit
public import AVFoundation
import CmuxNextDesign
import CoreImage
import QuartzCore

/// The geometry of the live preview's thumbnail, as the ChatGPT app docks its Computer Use
/// picture: at the top right of the agent's surface, the window's own aspect, its long side at
/// ``defaultLongSide`` (the person resizes it up to ``maximumLongSide``), the window's own corners
/// scaled down, no border, a very soft shadow. Pure: tests read it.
public nonisolated struct ComputerUsePreviewLayout: Equatable, Sendable {
    /// Below the surface's content top.
    public static let topInset: CGFloat = 24.5
    /// From the surface's side edge.
    public static let sideInset: CGFloat = 20.5
    public static let defaultLongSide: CGFloat = 200
    public static let minimumLongSide: CGFloat = 120
    public static let maximumLongSide: CGFloat = 400
    /// The window's corner radius scaled down to the thumbnail.
    public static let cornerRadius: CGFloat = 4.5
    /// The entrance: from this scale and blur, as ChatGPT's preview appears.
    public static let entranceScale: CGFloat = 0.72
    public static let entranceBlur: CGFloat = 18
    /// The expanded view's share of its surface.
    public static let expandedShare: CGFloat = 0.86

    /// A corner of the surface the thumbnail docks in (a drag snaps it to the nearest).
    public enum Corner: String, CaseIterable, Sendable {
        case topRight, topLeft, bottomRight, bottomLeft

        /// The corner nearest `point` in a surface of `size` (AppKit coordinates, origin bottom left).
        public static func nearest(to point: CGPoint, in size: CGSize) -> Corner {
            let right = point.x >= size.width / 2
            let top = point.y >= size.height / 2
            switch (top, right) {
            case (true, true): return .topRight
            case (true, false): return .topLeft
            case (false, true): return .bottomRight
            case (false, false): return .bottomLeft
            }
        }
    }

    /// The corner the thumbnail docks in.
    public var corner: Corner
    /// The thumbnail's long side before it shrinks to fit (the person's resize).
    public var longSide: CGFloat
    /// The picture's aspect (width / height).
    public var aspect: CGFloat

    public init(corner: Corner = .topRight, longSide: CGFloat = Self.defaultLongSide, aspect: CGFloat = 16.0 / 10.0) {
        self.corner = corner
        self.longSide = longSide
        self.aspect = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 10.0
    }

    /// The thumbnail's size: its long side ``longSide`` (within the allowed range), shrunk to fit a
    /// surface `available` wide less both insets.
    public func thumbnailSize(available: CGFloat) -> CGSize {
        let room = max(Self.minimumLongSide / 2, available - 2 * Self.sideInset)
        let side = min(max(longSide, Self.minimumLongSide), Self.maximumLongSide)
        var size = aspect >= 1 ? CGSize(width: side, height: side / aspect) : CGSize(width: side * aspect, height: side)
        if size.width > room { size = CGSize(width: room, height: room / aspect) }
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    /// The thumbnail's frame in a surface of `bounds` (AppKit coordinates, origin bottom left),
    /// docked in ``corner``: ``topInset`` below the top, ``sideInset`` from the side.
    public func thumbnailFrame(in bounds: CGSize) -> CGRect {
        let size = thumbnailSize(available: bounds.width)
        let left = Self.sideInset, right = bounds.width - Self.sideInset - size.width
        let top = bounds.height - Self.topInset - size.height, bottom = Self.sideInset
        let origin: CGPoint
        switch corner {
        case .topRight: origin = CGPoint(x: right, y: top)
        case .topLeft: origin = CGPoint(x: left, y: top)
        case .bottomRight: origin = CGPoint(x: right, y: bottom)
        case .bottomLeft: origin = CGPoint(x: left, y: bottom)
        }
        return CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }

    /// The restore chip's frame: always at the top right, where the thumbnail docks first.
    public func chipFrame(size: CGSize, in bounds: CGSize) -> CGRect {
        CGRect(x: bounds.width - Self.sideInset - size.width, y: bounds.height - Self.topInset - size.height,
               width: size.width, height: size.height)
    }

    /// The expanded view's size: the picture's aspect, at most ``expandedShare`` of `bounds`.
    public func expandedSize(in bounds: CGSize) -> CGSize {
        let width = bounds.width * Self.expandedShare, height = bounds.height * Self.expandedShare
        let size = width / height > aspect ? CGSize(width: height * aspect, height: height) : CGSize(width: width, height: width / aspect)
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }
}

/// What the person asks of a preview from its controls.
public enum ComputerUsePreviewRequest: Sendable, Equatable {
    case expand
    case collapse
    case showWindow
    case hideHere
    case hideEverywhere
    case show
    case moved(ComputerUsePreviewLayout.Corner)
    /// The grip moves: the card takes this long side now; the stream follows on ``resized(_:)``.
    case resizing(CGFloat)
    /// The resize ended at this long side.
    case resized(CGFloat)
}

/// The live thumbnail: the stream's layer under the window-like corners, controls that fade in on
/// hover over a blurred backdrop (Expand, Show Window, Hide), a drag that snaps to a corner, and a
/// resize grip. It never becomes first responder, so the person's typing stays where it is.
@MainActor
public final class ComputerUsePreviewThumbnail: NSView {
    public var onRequest: (ComputerUsePreviewRequest) -> Void = { _ in }
    /// The picture's aspect (width / height); the controller sets it from the stream's status.
    public var aspect: CGFloat = 16.0 / 10.0

    private let picture = NSView()
    private let still = CALayer()
    private weak var video: AVSampleBufferDisplayLayer?
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
        picture.wantsLayer = true
        picture.layer?.cornerRadius = ComputerUsePreviewLayout.cornerRadius
        picture.layer?.cornerCurve = .continuous
        picture.layer?.masksToBounds = true
        picture.layer?.backgroundColor = NSColor.clear.cgColor
        still.contentsGravity = .resizeAspect
        picture.layer?.addSublayer(still)
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
    public func attach(video layer: AVSampleBufferDisplayLayer?) {
        if let video, video.superlayer === picture.layer { video.removeFromSuperlayer() }
        video = layer
        if let layer { picture.layer?.insertSublayer(layer, below: still) }
        needsLayout = true
    }

    /// Shows a still in place of the video (nil: the video shows).
    public func show(still image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.contents = image
        CATransaction.commit()
    }

    /// A still is shown (tests).
    var showsStill: Bool { still.contents != nil }

    public override func layout() {
        super.layout()
        picture.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video?.frame = picture.bounds
        still.frame = picture.bounds
        CATransaction.commit()
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
        menu.addItem(PreviewMenuItem(title: ComputerUsePreviewText.hideHere) { [weak self] in self?.onRequest(.hideHere) })
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

/// The chip a hidden preview leaves at the top right of its surface; a click shows it again.
@MainActor
public final class ComputerUsePreviewChip: NSButton {
    private let onShow: () -> Void

    public init(onShow: @escaping () -> Void) {
        self.onShow = onShow
        super.init(frame: .zero)
        title = ComputerUsePreviewText.chip
        image = NSImage(systemSymbolName: "pip", accessibilityDescription: nil)
        imagePosition = .imageLeading
        font = NSFont.systemFont(ofSize: TypeScale.caption, weight: TypeScale.emphasis)
        bezelStyle = .inline
        controlSize = .small
        refusesFirstResponder = true
        toolTip = ComputerUsePreviewText.chipHelp
        target = self
        action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var acceptsFirstResponder: Bool { false }

    @objc private func clicked() { onShow() }
}

/// The expanded view: the live picture large over a dimmed surface. A click anywhere or Escape
/// (the controller's key monitor) closes it; it never takes the keyboard.
@MainActor
public final class ComputerUsePreviewExpanded: NSView {
    public var onClose: () -> Void = {}
    public var aspect: CGFloat = 16.0 / 10.0 { didSet { needsLayout = true } }
    private let scrim = NSView()
    private let picture = NSView()
    private let still = CALayer()
    private weak var video: AVSampleBufferDisplayLayer?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        still.contentsGravity = .resizeAspect
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        addSubview(scrim)
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 8
        picture.layer?.cornerCurve = .continuous
        picture.layer?.masksToBounds = true
        picture.shadow = NSShadow()
        picture.layer?.addSublayer(still)
        addSubview(picture)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(ComputerUsePreviewText.expandedLabel)
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public func attach(video layer: AVSampleBufferDisplayLayer?) {
        if let video, video.superlayer === picture.layer { video.removeFromSuperlayer() }
        video = layer
        if let layer { picture.layer?.insertSublayer(layer, below: still) }
        needsLayout = true
    }

    /// Shows a still in place of the video (nil: the video shows).
    public func show(still image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.contents = image
        CATransaction.commit()
    }

    /// A still is shown (tests).
    var showsStill: Bool { still.contents != nil }

    public override func layout() {
        super.layout()
        scrim.frame = bounds
        let size = ComputerUsePreviewLayout(aspect: aspect).expandedSize(in: bounds.size)
        picture.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video?.frame = picture.bounds
        still.frame = picture.bounds
        CATransaction.commit()
    }

    public override func mouseDown(with event: NSEvent) { onClose() }
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

/// The preview's strings.
@MainActor
public struct ComputerUsePreviewText {
    public static var thumbnailLabel: String {
        String(localized: "computerUse.preview.label", defaultValue: "Computer Use preview", table: "CmuxRemote", bundle: .module)
    }
    public static var expandedLabel: String {
        String(localized: "computerUse.preview.expandedLabel", defaultValue: "Computer Use preview, expanded",
               table: "CmuxRemote", bundle: .module)
    }
    public static var expand: String {
        String(localized: "computerUse.preview.expand", defaultValue: "Expand", table: "CmuxRemote", bundle: .module)
    }
    public static var showWindow: String {
        String(localized: "computerUse.preview.showWindow", defaultValue: "Show Window", table: "CmuxRemote", bundle: .module)
    }
    public static var hide: String {
        String(localized: "computerUse.preview.hide", defaultValue: "Hide", table: "CmuxRemote", bundle: .module)
    }
    public static var hideHere: String {
        String(localized: "computerUse.preview.hideHere", defaultValue: "Hide for This Chat", table: "CmuxRemote", bundle: .module)
    }
    public static var hideEverywhere: String {
        String(localized: "computerUse.preview.hideEverywhere", defaultValue: "Hide for All Active Chats", table: "CmuxRemote",
               bundle: .module)
    }
    public static var chip: String {
        String(localized: "computerUse.preview.chip", defaultValue: "Live Preview", table: "CmuxRemote", bundle: .module)
    }
    public static var chipHelp: String {
        String(localized: "computerUse.preview.chipHelp", defaultValue: "Show the live preview of the window the agent uses",
               table: "CmuxRemote", bundle: .module)
    }

    public init() {}
}
