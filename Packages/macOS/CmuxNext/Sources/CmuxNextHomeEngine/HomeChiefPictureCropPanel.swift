public import AppKit
import CmuxNextDesign

/// Move and Scale for a Chief's new picture, as Messages edits a contact photo: the picture
/// under a circle, dragged to move it and scrolled, pinched or slid to zoom; Save keeps the
/// circle's square (``HomeChiefPictureCrop``). One small panel, a child of the window the card was in.
@MainActor
final class HomeChiefPictureCropPanel {
    private var panel: NSPanel?

    /// Shows `image` (the upright picture) to crop over `window`; `onSave` gets the saved
    /// picture. A new picture replaces one still being edited.
    func show(_ image: CGImage, over window: NSWindow?, onSave: @escaping (ChiefAvatarPicture) -> Void) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let view = HomeChiefPictureCropView(image: image)
        view.onDone = { [weak panel] picture in
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            if let picture { onSave(picture) }
        }
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        panel.parent?.removeChildWindow(panel)
        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
            // A child of the window the card was in: it moves with it and stays over it.
            window.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view.canvas)
    }

    /// The editor shown now, if any (Debug captures).
    var view: HomeChiefPictureCropView? { panel?.isVisible == true ? panel?.contentView as? HomeChiefPictureCropView : nil }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.title = HomeEngineStrings.cropTitle
        panel.setAccessibilityIdentifier("cmux.home.chief.pictureCrop")
        return panel
    }
}

/// The crop panel's content: the canvas, the zoom slider, a hint, then Cancel and Save.
@MainActor
final class HomeChiefPictureCropView: NSView {
    let canvas: HomeChiefPictureCropCanvas
    private let slider = NSSlider(value: 1, minValue: 1, maxValue: Double(HomeChiefPictureCrop.maximumZoom), target: nil, action: nil)
    /// The saved picture, or nil for Cancel (and for a picture that could not be drawn).
    var onDone: (ChiefAvatarPicture?) -> Void = { _ in }

    init(image: CGImage) {
        canvas = HomeChiefPictureCropCanvas(image: image)
        super.init(frame: .zero)
        let hint = ThemedLabel(labelWithString: HomeEngineStrings.cropHint)
        hint.font = Typography.caption
        hint.ink = .secondary
        hint.alignment = .center
        slider.target = self
        slider.action = #selector(zoomed)
        slider.isContinuous = true
        slider.setAccessibilityLabel(HomeEngineStrings.cropZoom)
        slider.setAccessibilityIdentifier("cmux.home.chief.pictureCrop.zoom")
        canvas.onZoom = { [weak self] zoom in self?.slider.doubleValue = Double(zoom) }
        let cancel = CmuxDialogButtonView(standalone: .cancel(), target: self, action: #selector(cancelled))
        let save = CmuxDialogButtonView(standalone: CmuxDialogButton(id: "save", title: HomeEngineStrings.cropSave, role: .default),
                                        target: self, action: #selector(saved))
        let buttons = NSStackView(views: [cancel, save])
        buttons.spacing = 8
        let stack = NSStackView(views: [canvas, slider, hint, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            slider.widthAnchor.constraint(equalTo: canvas.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func zoomed() {
        canvas.setZoom(CGFloat(slider.doubleValue))
    }

    @objc private func cancelled() {
        onDone(nil)
    }

    @objc func saved() {
        onDone(try? canvas.crop.render(canvas.image))
    }
}

/// The picture under the circle: what is outside the circle is dimmed; a drag moves the
/// picture, a scroll or a pinch zooms it.
@MainActor
final class HomeChiefPictureCropCanvas: NSView {
    /// The canvas's side, and the circle's diameter inside it.
    static let side: CGFloat = 280
    static let diameter: CGFloat = 240

    let image: CGImage
    private(set) var crop: HomeChiefPictureCrop
    /// The zoom changed from the canvas (a scroll or a pinch): the slider follows.
    var onZoom: (CGFloat) -> Void = { _ in }

    init(image: CGImage) {
        self.image = image
        crop = HomeChiefPictureCrop(imageSize: CGSize(width: image.width, height: image.height))
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: Self.side), heightAnchor.constraint(equalToConstant: Self.side)])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(HomeEngineStrings.cropTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func setZoom(_ zoom: CGFloat) {
        crop.zoom = zoom
        needsDisplay = true
    }

    /// The circle's square in the canvas.
    private var circleRect: NSRect {
        NSRect(x: (bounds.width - Self.diameter) / 2, y: (bounds.height - Self.diameter) / 2, width: Self.diameter, height: Self.diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let circle = circleRect
        // The whole picture, placed so the crop's square fills the circle's square.
        let scale = Self.diameter / crop.side
        let rect = crop.rect
        let drawn = CGRect(x: circle.minX - rect.minX * scale,
                           y: circle.maxY - (crop.imageSize.height - rect.minY) * scale,
                           width: crop.imageSize.width * scale, height: crop.imageSize.height * scale)
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: drawn)
        context.restoreGState()
        performWithTheme {
            // Dim everything outside the circle, then ring it.
            let outside = NSBezierPath(rect: bounds)
            outside.append(NSBezierPath(ovalIn: circle))
            outside.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill()
            outside.fill()
            Palette.separator.setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDragged(with event: NSEvent) {
        crop.pan(by: CGSize(width: event.deltaX, height: -event.deltaY), diameter: Self.diameter)
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        // A scroll moves the zoom by a tenth of its range per notch (precise trackpads: per point).
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 10
        zoom(by: step)
    }

    override func magnify(with event: NSEvent) {
        zoom(by: event.magnification * crop.zoom)
    }

    private func zoom(by delta: CGFloat) {
        guard delta != 0 else { return }
        crop.zoom += delta
        needsDisplay = true
        onZoom(crop.zoom)
    }
}
