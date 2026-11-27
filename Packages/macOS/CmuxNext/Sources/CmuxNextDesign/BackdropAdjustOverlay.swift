public import AppKit
public import CmuxNextDesignTokens

/// Adjust Background… (`appearance.adjustBackground`, Leo 2026-11-22: "we also want people to be able
/// to reposition the images easily. the fast-actions need to be most accessible."): a clear layer over
/// the window where a drag moves the picture, a scroll or pinch zooms it, and a small bar offers Fill,
/// Fit, Center, Reset and Done. The backdrop previews each step live (``WindowMaterialView/previewPlacement``);
/// the setting is written once, on Done (Return too). Esc cancels: the picture goes back to where it
/// was and nothing is written; so does closing the window or the picture changing underneath.
public final class BackdropAdjustOverlay: NSView {
    /// The picture the placement is for (`appearance.backgroundPlacement`'s key, ``BackdropPlacement/key(picture:)``).
    public let pictureID: String
    /// The placement shown now.
    public private(set) var placement: BackdropPlacement
    private weak var backdrop: WindowMaterialView?
    private let image: CGSize
    private let onDone: @MainActor (_ pictureID: String, _ placement: BackdropPlacement) -> Void
    private var lastPoint: NSPoint?
    /// A plain dark bar like a player's controls: this is editing chrome over the picture for a
    /// moment, not a glass surface (design/surface-materials.md).
    private let bar = NSView()
    private var finished = false

    /// Starts adjusting what `backdrop` shows, over its window's content; nil when it shows no picture
    /// or is in no window. `onDone` gets the placement once, when the person is done.
    @discardableResult
    public static func begin(on backdrop: WindowMaterialView,
                             onDone: @escaping @MainActor (_ pictureID: String, _ placement: BackdropPlacement) -> Void) -> BackdropAdjustOverlay? {
        guard let image = backdrop.placementImageSize, image.width > 0, image.height > 0,
              let pictureID = backdrop.placementPictureID,
              let window = backdrop.window, let content = window.contentView else { return nil }
        if let open = content.subviews.lazy.compactMap({ $0 as? BackdropAdjustOverlay }).first { return open }
        let overlay = BackdropAdjustOverlay(backdrop: backdrop, pictureID: pictureID, image: image, onDone: onDone)
        backdrop.adjusting = overlay
        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        FocusRoute(.person, "Adjust Background takes Esc and Return").moveKeyboard(in: window, to: overlay)
        return overlay
    }

    private init(backdrop: WindowMaterialView, pictureID: String, image: CGSize,
                 onDone: @escaping @MainActor (_ pictureID: String, _ placement: BackdropPlacement) -> Void) {
        self.backdrop = backdrop
        self.image = image
        self.onDone = onDone
        self.pictureID = pictureID
        placement = backdrop.placement ?? .centeredFill
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.text(.title))
        buildBar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var acceptsFirstResponder: Bool { true }

    override public func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // MARK: Gestures

    override public func mouseDown(with event: NSEvent) {
        lastPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
    }

    override public func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { lastPoint = point }
        guard let lastPoint, let view = backdrop?.bounds.size else { return }
        show(Self.dragged(placement, image: image, view: view, from: lastPoint, to: point))
    }

    override public func mouseUp(with event: NSEvent) {
        lastPoint = nil
        NSCursor.openHand.set()
    }

    override public func scrollWheel(with event: NSEvent) {
        show(placement.zoomed(by: Self.scrollZoom(deltaY: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas)))
    }

    override public func magnify(with event: NSEvent) {
        show(placement.zoomed(by: 1 + Double(event.magnification)))
    }

    override public func keyDown(with event: NSEvent) {
        // Return (36) and Enter (76) are Done; Esc (53) cancels.
        if [36, 76].contains(event.keyCode) { return finish() }
        if event.keyCode == 53 { return cancel() }
        super.keyDown(with: event)
    }

    override public func cancelOperation(_ sender: Any?) { cancel() }

    /// Closing the window, or the overlay leaving it any other way, cancels.
    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, !finished { end(saving: false) }
    }

    /// The placement after the pointer moved `from` to `to` (this view's bottom-left points): the
    /// picture follows the pointer (``BackdropPlacement/dragged(image:view:dx:dy:)``, y flipped).
    nonisolated static func dragged(_ placement: BackdropPlacement, image: CGSize, view: CGSize, from: NSPoint, to: NSPoint) -> BackdropPlacement {
        placement.dragged(image: image, view: view, dx: Double(to.x - from.x), dy: Double(from.y - to.y))
    }

    /// The zoom factor of one scroll step: up zooms in. A trackpad's fine deltas scale less than a
    /// wheel's lines.
    nonisolated static func scrollZoom(deltaY: Double, precise: Bool) -> Double {
        exp(deltaY * (precise ? 0.005 : 0.05))
    }

    // MARK: The bar

    enum Choice: Int, CaseIterable {
        case fill, fit, center, reset, done
    }

    /// What a bar button does to `placement`; nil for Done.
    nonisolated static func choose(_ choice: Choice, on placement: BackdropPlacement) -> BackdropPlacement? {
        switch choice {
        case .fill: BackdropPlacement(mode: .fill, x: placement.x, y: placement.y)
        case .fit: BackdropPlacement(mode: .fit, x: placement.x, y: placement.y)
        case .center: BackdropPlacement(mode: .center)
        case .reset: .centeredFill
        case .done: nil
        }
    }

    private func buildBar() {
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        bar.layer?.cornerRadius = 10
        bar.layer?.masksToBounds = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        let hint = NSTextField(labelWithString: Self.text(.hint))
        hint.textColor = NSColor.white.withAlphaComponent(0.8)
        hint.font = Typography.caption
        var views: [NSView] = [hint]
        for choice in Choice.allCases {
            let button = ThemedBezelButton(frame: .zero)
            button.title = Self.text(choice.label)
            button.target = self
            button.action = #selector(pressed(_:))
            button.tag = choice.rawValue
            if choice == .done { button.keyHint = .return }
            views.append(button)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        addSubview(bar)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor), stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor), bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let choice = Choice(rawValue: sender.tag) else { return }
        guard let next = Self.choose(choice, on: placement) else { return finish() }
        show(next)
    }

    func show(_ next: BackdropPlacement) {
        guard !finished else { return }
        placement = next
        backdrop?.previewPlacement = next
    }

    /// Done: hands the placement on once, then the preview ends and the overlay goes.
    func finish() { end(saving: true) }

    /// Esc, a closed window or another picture: the preview ends, the picture is back where it
    /// was, and nothing is handed on.
    func cancel() { end(saving: false) }

    private func end(saving: Bool) {
        guard !finished else { return }
        finished = true
        if saving { onDone(pictureID, placement) }
        if backdrop?.adjusting === self { backdrop?.adjusting = nil }
        backdrop?.previewPlacement = nil
        if let window { FocusRoute(.person, "Adjust Background is done").moveKeyboard(in: window, to: nil) }
        if superview != nil { removeFromSuperview() }
    }

    // MARK: Strings

    enum Text {
        case title, hint, fill, fit, center, reset, done, noPicture
    }

    static func text(_ text: Text) -> String {
        switch text {
        case .title: String(localized: "backdrop.adjust.title", defaultValue: "Adjust Background", bundle: .localizedModule)
        case .hint: String(localized: "backdrop.adjust.hint", defaultValue: "Drag to move, scroll or pinch to zoom", bundle: .localizedModule)
        case .fill: String(localized: "backdrop.adjust.fill", defaultValue: "Fill", bundle: .localizedModule)
        case .fit: String(localized: "backdrop.adjust.fit", defaultValue: "Fit", bundle: .localizedModule)
        case .center: String(localized: "backdrop.adjust.center", defaultValue: "Center", bundle: .localizedModule)
        case .reset: String(localized: "backdrop.adjust.reset", defaultValue: "Reset", bundle: .localizedModule)
        case .done: String(localized: "backdrop.adjust.done", defaultValue: "Done", bundle: .localizedModule)
        case .noPicture: String(localized: "backdrop.adjust.noPicture", defaultValue: "This window shows no background picture to place", bundle: .localizedModule)
        }
    }

    /// The refusal when the window shows no picture (a plain color, the desktop through glass).
    public static var noPictureText: String { text(.noPicture) }
}

private extension BackdropAdjustOverlay.Choice {
    var label: BackdropAdjustOverlay.Text {
        switch self {
        case .fill: .fill
        case .fit: .fit
        case .center: .center
        case .reset: .reset
        case .done: .done
        }
    }
}
