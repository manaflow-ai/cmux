public import AppKit
import CmuxNextDesign
import CmuxNextIcons
import ImageIO

/// The live preview card of Computer Use in a terminal pane, the native twin of the agent chat's
/// card (webviews `ComputerUsePreviewCard.tsx`): while the agent running in this terminal drives an
/// app, a live view of that app's window at the pane's top-trailing corner, the agent's cursor
/// drawn where it acts; when its Computer Use ends, the last frame dims under a green check.
/// A click on the card enlarges it (and back); a drag moves it anywhere inside the pane; the
/// full-size button makes it fill the pane; the close button hides it to a "Show Preview" chip
/// that brings it back (Leo, 2026-11-22, asking for "the ability to drag it around and" hide it).
/// Where it sits, its size and whether it is hidden are the daemon's, per session (each card
/// carries them); the card keeps the person's own move until a card echoes it.
///
/// It only draws: what to show, when, and for which agent is cmux Computer Use's (the worker's
/// preview hub, routed by the App), and a frame's JPEG is decoded off the main thread.
public final class TerminalComputerUsePreview: NSView {
    /// One card as the worker's preview sends it (`computer-use-preview`'s `card`).
    public struct Card: Equatable, Sendable {
        public var session: String
        public var app: String
        public var done: Bool
        /// The newest frame, a `data:image/jpeg;base64,` URL.
        public var frame: String
        /// The agent's cursor as a fraction of the window (0...1 from the top left), and its clicks.
        public var pointer: CGPoint?
        public var clicks: Int
        /// Where the daemon keeps the card; nil from a daemon that keeps none.
        public var place: Place?
        /// The person hid the card: it shows as the chip.
        public var hidden: Bool

        public init(session: String, app: String, done: Bool, frame: String, pointer: CGPoint? = nil, clicks: Int = 0,
                    place: Place? = nil, hidden: Bool = false) {
            self.session = session
            self.app = app
            self.done = done
            self.frame = frame
            self.pointer = pointer
            self.clicks = clicks
            self.place = place
            self.hidden = hidden
        }

        /// The card of a preview line's `card` object; nil for none or a malformed one.
        public init?(json: [String: Any]?) {
            guard let json, let session = json["session"] as? String, !session.isEmpty,
                  let frame = json["frame"] as? String, frame.hasPrefix("data:image/") else { return nil }
            var pointer: CGPoint?
            var clicks = 0
            if let p = json["pointer"] as? [String: Any], let x = (p["x"] as? NSNumber)?.doubleValue,
               let y = (p["y"] as? NSNumber)?.doubleValue, (0...1).contains(x), (0...1).contains(y) {
                pointer = CGPoint(x: x, y: y)
                clicks = (p["click"] as? NSNumber)?.intValue ?? 0
            }
            var place: Place?
            if let p = json["place"] as? [String: Any], let x = (p["x"] as? NSNumber)?.doubleValue,
               let y = (p["y"] as? NSNumber)?.doubleValue {
                place = Place(x: x, y: y, size: (p["size"] as? String).flatMap(Size.init(rawValue:)) ?? .small)
            }
            self.init(session: session, app: json["app"] as? String ?? "", done: json["done"] as? Bool ?? false,
                      frame: frame, pointer: pointer, clicks: clicks, place: place, hidden: json["hidden"] as? Bool ?? false)
        }
    }

    /// The card's size: small, enlarged, or filling the pane.
    public enum Size: String, Equatable, Sendable {
        case small, large, full
    }

    /// Where the card sits: fractions of the room the pane leaves around it (`x` 0 at the leading
    /// edge, 1 at the trailing; `y` 0 at the top, 1 at the bottom), and its size.
    public struct Place: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var size: Size

        /// The top-trailing corner, small: where the card sat before it could move.
        public init(x: Double = 1, y: Double = 0, size: Size = .small) {
            self.x = min(1, max(0, x))
            self.y = min(1, max(0, y))
            self.size = size
        }
    }

    /// The person's change to the card (a nil keeps its value).
    public struct Move: Equatable, Sendable {
        public var x: Double?
        public var y: Double?
        public var size: Size?

        public init(x: Double? = nil, y: Double? = nil, size: Size? = nil) {
            self.x = x
            self.y = y
            self.size = size
        }
    }

    /// The close button's fill: a dark translucent circle readable over a light or a dark window,
    /// as the agent chat's card draws it (`--cu-preview-close-fill`).
    static let closeFill = NSColor.black.withAlphaComponent(0.52)

    /// The small card's width; the enlarged one takes up to ``expandedFraction`` of the pane.
    public static let width: CGFloat = 180
    public static let expandedWidth: CGFloat = 560
    public static let expandedFraction: CGFloat = 0.6

    /// A press that moves less than this is a click (enlarge), more a drag.
    static let dragSlop: CGFloat = 4

    /// The person closed it: the App hides this session's card from now on.
    public var onClose: (@MainActor (_ session: String) -> Void)?
    /// The person brought the hidden card back (the chip).
    public var onShow: (@MainActor (_ session: String) -> Void)?
    /// The person dragged or resized the card.
    public var onMove: (@MainActor (_ session: String, _ move: Move) -> Void)?
    /// The card shown, nil while none.
    public private(set) var card: Card?
    /// Where the card sits: the daemon's place, with the person's move over it until echoed.
    public private(set) var place = Place()
    /// The person's move not yet echoed by a card.
    private var pending: Move?
    /// The person hid the card and no card said so yet (an old daemon never will).
    private var hiddenHere = false
    /// Dragging, full size and the "Show Preview" chip (Settings > Advanced > Labs > Show Preview
    /// Features, off by default). Off, the card is the top right card a click enlarges and the close
    /// button hides for the session; a place or hidden flag the daemon keeps is not drawn.
    public var movable = false {
        didSet {
            guard oldValue != movable else { return }
            sizeChanged()
            layoutContents()
            if gone { isHidden = true } else if isHidden, frameLayer.contents != nil || collapsed { isHidden = false }
        }
    }
    /// The place drawn: ``place``, or with the controls off the top right at small or large.
    private var drawn: Place { movable ? place : Place(size: place.size == .large ? .large : .small) }
    public var expanded: Bool { drawn.size == .large }
    public var full: Bool { drawn.size == .full }
    /// The person (or the daemon) hid the card.
    private var hiddenCard: Bool { card != nil && (hiddenHere || card?.hidden == true) }
    /// Showing as the "Show Preview" chip.
    public var collapsed: Bool { movable && hiddenCard }
    /// Hidden with the controls off: no chip, no card.
    private var gone: Bool { !movable && hiddenCard }
    /// The width of the pane the card sits in (the host sets it on layout).
    var paneWidth: CGFloat = 800 { didSet { if oldValue != paneWidth { invalidateIntrinsicContentSize() } } }
    /// Where the card may go in its host: the pane less its margins and the find bar (the host
    /// sets it on layout).
    var area: CGRect = CGRect(x: 12, y: 12, width: 776, height: 576) {
        didSet { if oldValue.size != area.size, full { invalidateIntrinsicContentSize() } }
    }

    private let frameLayer = CALayer()
    private let dim = CALayer()
    private let cursor = CAShapeLayer()
    private let badge = CAShapeLayer()
    private let checkmark = CAShapeLayer()
    private let closeButton = NSButton()
    private let fullButton = NSButton()
    private let chip = NSButton()
    private var aspect: CGFloat = 0.625
    private var decoding: String?

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        frameLayer.masksToBounds = true
        frameLayer.cornerRadius = 10
        frameLayer.contentsGravity = .resizeAspectFill
        frameLayer.borderWidth = Metrics.lineWidth(1)
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dim.isHidden = true
        frameLayer.addSublayer(dim)
        cursor.path = Self.arrow
        cursor.fillColor = NSColor(srgbRed: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255, alpha: 1).cgColor // colour-allow: the agent cursor's blue (#0A84FF), the same constant cmux Remote's cursor overlay draws, so the preview's cursor matches the one on screen
        cursor.strokeColor = NSColor.white.cgColor
        cursor.lineWidth = 1.2
        cursor.isHidden = true
        frameLayer.addSublayer(cursor)
        badge.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 24, height: 24), transform: nil)
        badge.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        badge.fillColor = NSColor.systemGreen.cgColor
        badge.strokeColor = NSColor.white.cgColor
        badge.lineWidth = 1.5
        badge.isHidden = true
        checkmark.path = Self.check
        checkmark.frame = badge.bounds
        checkmark.fillColor = nil
        checkmark.strokeColor = NSColor.white.cgColor
        checkmark.lineWidth = 2.2
        checkmark.lineCap = .round
        checkmark.lineJoin = .round
        badge.addSublayer(checkmark)
        frameLayer.addSublayer(badge)
        layer?.addSublayer(frameLayer)
        closeButton.image = NSImage.icon(.actionClose, size: 10)
        closeButton.contentTintColor = .white
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 9 // radius-allow: an 18 pt circle (bezelStyle .circular) floating over the window preview, not a toolbar button
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.setAccessibilityLabel(String(localized: "terminal.computerUsePreview.close", defaultValue: "Hide Preview", bundle: .localizedModule))
        addSubview(closeButton)
        fullButton.image = NSImage.icon(.viewExpand, size: 10)
        fullButton.contentTintColor = .white
        fullButton.bezelStyle = .circular
        fullButton.isBordered = false
        fullButton.wantsLayer = true
        fullButton.layer?.cornerRadius = 9 // radius-allow: the 18 pt circle beside the close button, the same chrome
        fullButton.target = self
        fullButton.action = #selector(toggleFull)
        addSubview(fullButton)
        chip.title = String(localized: "terminal.computerUsePreview.show", defaultValue: "Show Preview", bundle: .localizedModule)
        chip.image = NSImage.icon(.computeruseObserve, size: 12)
        chip.imagePosition = .imageLeading
        chip.bezelStyle = .rounded
        chip.controlSize = .small
        chip.target = self
        chip.action = #selector(showAgain)
        chip.isHidden = true
        addSubview(chip)
        updateFullLabel()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `card` (nil hides it). A new frame shows once it decoded, so the card never blanks.
    public func show(_ card: Card?) {
        let previous = self.card
        self.card = card
        guard let card else {
            isHidden = true
            place = Place()
            pending = nil
            hiddenHere = false
            frameLayer.contents = nil
            decoding = nil
            superview?.needsLayout = true
            return
        }
        let wasCollapsed = movable && previous != nil && (hiddenHere || previous?.hidden == true)
        let before = place
        if previous?.session != card.session {
            place = card.place ?? Place()
            pending = nil
            hiddenHere = false
        } else if let echoed = card.place {
            if let pending, !Self.echoes(echoed, pending) {
                // A frame sent before the daemon had the person's move: keep the move.
            } else {
                pending = nil
                place = echoed
            }
        }
        if hiddenHere, card.hidden { hiddenHere = false }
        setAccessibilityLabel(Self.label(card))
        if card.frame != previous?.frame { decode(card.frame) }
        if place.size != before.size || collapsed != wasCollapsed { sizeChanged() } else if place != before { superview?.needsLayout = true }
        if previous?.done != card.done || previous?.pointer != card.pointer || collapsed != wasCollapsed { layoutContents() }
        if gone { isHidden = true } else if isHidden, frameLayer.contents != nil || collapsed { isHidden = false }
    }

    /// Whether the daemon's `place` has every part of the person's `move`.
    static func echoes(_ place: Place, _ move: Move) -> Bool {
        (move.x.map { abs($0 - place.x) < 0.0005 } ?? true) && (move.y.map { abs($0 - place.y) < 0.0005 } ?? true)
            && (move.size.map { $0 == place.size } ?? true)
    }

    /// The person's change: drawn now, sent to the App, kept until a card echoes it.
    func move(_ change: Move) {
        guard let session = card?.session else { return }
        let before = place
        place = Place(x: change.x ?? place.x, y: change.y ?? place.y, size: change.size ?? place.size)
        pending = Move(x: change.x ?? pending?.x, y: change.y ?? pending?.y, size: change.size ?? pending?.size)
        if place.size != before.size { sizeChanged() } else { superview?.needsLayout = true }
        onMove?(session, change)
    }

    private func sizeChanged() {
        updateFullLabel()
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    private func updateFullLabel() {
        fullButton.setAccessibilityLabel(full
            ? String(localized: "terminal.computerUsePreview.exitFullSize", defaultValue: "Exit Full Size", bundle: .localizedModule)
            : String(localized: "terminal.computerUsePreview.fullSize", defaultValue: "Full Size", bundle: .localizedModule))
    }

    /// The card's origin in its host for a card of `size`: its place in the room ``area`` leaves.
    func origin(for size: CGSize) -> CGPoint {
        let room = CGSize(width: max(0, area.width - size.width), height: max(0, area.height - size.height))
        // AppKit grows up: y 0 (the top) is the area's top edge.
        let place = drawn
        return CGPoint(x: area.minX + CGFloat(place.x) * room.width, y: area.maxY - size.height - CGFloat(place.y) * room.height)
    }

    /// The place of a card whose origin is `origin`: the inverse of ``origin(for:)``, clamped.
    func fractions(of origin: CGPoint, size: CGSize) -> (x: Double, y: Double) {
        let room = CGSize(width: max(0, area.width - size.width), height: max(0, area.height - size.height))
        let x = room.width > 0 ? (origin.x - area.minX) / room.width : place.x
        let y = room.height > 0 ? (area.maxY - size.height - origin.y) / room.height : place.y
        return (min(1, max(0, Double(x))), min(1, max(0, Double(y))))
    }

    private func decode(_ url: String) {
        decoding = url
        // task-owner: one frame's decode; a newer frame or a hide supersedes it (`decoding`).
        Task { [weak self] in
            let image = await Self.decoded(url)
            guard let self, self.decoding == url, let image else { return }
            self.decoding = nil
            let aspect = image.width > 0 ? CGFloat(image.height) / CGFloat(image.width) : self.aspect
            let resized = abs(aspect - self.aspect) > 0.001
            self.aspect = aspect
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.frameLayer.contents = image
            CATransaction.commit()
            if self.card != nil { self.isHidden = false }
            if resized { self.invalidateIntrinsicContentSize() }
            self.superview?.needsLayout = true
        }
    }

    /// The JPEG of a frame's data URL, decoded off the main thread.
    @concurrent nonisolated static func decoded(_ url: String) async -> CGImage? {
        image(fromDataURL: url)
    }

    nonisolated static func image(fromDataURL url: String) -> CGImage? {
        guard let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public override var intrinsicContentSize: NSSize {
        if collapsed { return chip.fittingSize }
        if full {
            let width = max(Self.width, min(area.width, area.height / max(aspect, 0.01)))
            return NSSize(width: width.rounded(), height: (width * aspect).rounded())
        }
        let width = expanded ? min(Self.expandedWidth, max(Self.width, paneWidth * Self.expandedFraction)) : Self.width
        return NSSize(width: width, height: (width * aspect).rounded())
    }

    public override var fittingSize: NSSize { intrinsicContentSize }

    public override func layout() {
        super.layout()
        layoutContents()
    }

    private func layoutContents() {
        let collapsed = collapsed
        chip.isHidden = !collapsed
        frameLayer.isHidden = collapsed
        closeButton.isHidden = collapsed
        fullButton.isHidden = collapsed || !movable
        if collapsed { chip.frame = bounds }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        dim.frame = frameLayer.bounds
        let done = card?.done ?? false
        dim.isHidden = !done
        badge.isHidden = !done
        badge.position = CGPoint(x: bounds.midX, y: bounds.midY)
        if let pointer = card?.pointer, !done {
            cursor.isHidden = false
            // Flipped: AppKit layers grow up; the pointer's y is from the top.
            cursor.position = CGPoint(x: pointer.x * bounds.width, y: (1 - pointer.y) * bounds.height - 16)
        } else {
            cursor.isHidden = true
        }
        CATransaction.commit()
        closeButton.frame = CGRect(x: 6, y: bounds.height - 24, width: 18, height: 18)
        fullButton.frame = CGRect(x: 28, y: bounds.height - 24, width: 18, height: 18)
        performWithTheme {
            frameLayer.borderColor = Palette.separator.cgColor
            closeButton.layer?.backgroundColor = Self.closeFill.cgColor
            fullButton.layer?.backgroundColor = Self.closeFill.cgColor
        }
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A press on the card that does not move enlarges or shrinks it; one that moves past
    /// ``dragSlop`` drags the card inside the pane and leaves it there. The press follows its own
    /// drag and release (the pane's window may route the release elsewhere), never past a few
    /// seconds of silence, and never reaches the terminal under the card.
    public override func mouseDown(with event: NSEvent) {
        guard card != nil, !collapsed else { return }
        guard movable, let window, superview != nil, !full else { return toggleExpanded() }
        let start = event.locationInWindow
        let origin = frame.origin
        var dragged = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(timeIntervalSinceNow: 5),
                                          inMode: .eventTracking, dequeue: true) {
            let delta = CGPoint(x: next.locationInWindow.x - start.x, y: next.locationInWindow.y - start.y)
            if !dragged, hypot(delta.x, delta.y) >= Self.dragSlop { dragged = true }
            if dragged {
                let to = fractions(of: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y), size: frame.size)
                setFrameOrigin(self.origin(for: frame.size, at: to))
            }
            if next.type == .leftMouseUp { break }
        }
        if dragged {
            let to = fractions(of: frame.origin, size: frame.size)
            move(Move(x: to.x, y: to.y))
        } else {
            toggleExpanded()
        }
    }

    /// ``origin(for:)`` at the fractions `at` instead of the card's place.
    private func origin(for size: CGSize, at: (x: Double, y: Double)) -> CGPoint {
        let room = CGSize(width: max(0, area.width - size.width), height: max(0, area.height - size.height))
        return CGPoint(x: area.minX + CGFloat(at.x) * room.width, y: area.maxY - size.height - CGFloat(at.y) * room.height)
    }

    public override func mouseUp(with event: NSEvent) {}

    public override func accessibilityPerformPress() -> Bool {
        toggleExpanded()
        return true
    }

    /// The small card enlarges, the large one (or the full one) shrinks back.
    public func toggleExpanded() {
        guard card != nil else { return }
        move(Move(size: drawn.size == .small ? .large : .small))
    }

    /// The card fills the pane, or goes back to small.
    @objc public func toggleFull() {
        guard movable, card != nil else { return }
        move(Move(size: full ? .small : .full))
    }

    /// The person hid the card: it shows as the chip (with the controls off, it goes); the App tells
    /// the daemon.
    @objc private func close() {
        guard let session = card?.session else { return }
        guard movable else {
            show(nil)
            onClose?(session)
            return
        }
        hiddenHere = true
        sizeChanged()
        layoutContents()
        onClose?(session)
    }

    /// The chip: the card comes back.
    @objc private func showAgain() {
        guard let session = card?.session else { return }
        hiddenHere = false
        card?.hidden = false
        sizeChanged()
        layoutContents()
        onShow?(session)
    }

    private static func label(_ card: Card) -> String {
        let app = card.app.trimmingCharacters(in: .whitespaces)
        if card.done {
            return app.isEmpty
                ? String(localized: "terminal.computerUsePreview.doneNoApp", defaultValue: "App preview, done", bundle: .localizedModule)
                : String(localized: "terminal.computerUsePreview.done", defaultValue: "\(app), done", bundle: .localizedModule)
        }
        return app.isEmpty
            ? String(localized: "terminal.computerUsePreview.runningNoApp", defaultValue: "Live app preview", bundle: .localizedModule)
            : String(localized: "terminal.computerUsePreview.running", defaultValue: "\(app), live", bundle: .localizedModule)
    }

    /// The agent cursor's arrow (the worker's cursor shape, small), tip at the layer's origin.
    private static let arrow: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 16))
        path.addLine(to: CGPoint(x: 0, y: 2))
        path.addLine(to: CGPoint(x: 4, y: 6))
        path.addLine(to: CGPoint(x: 7, y: 0))
        path.addLine(to: CGPoint(x: 9, y: 1))
        path.addLine(to: CGPoint(x: 6, y: 7))
        path.addLine(to: CGPoint(x: 11, y: 7))
        path.closeSubpath()
        return path
    }()

    /// The white check on the green disc (24 pt).
    private static let check: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 7, y: 12.5))
        path.addLine(to: CGPoint(x: 10.5, y: 9))
        path.addLine(to: CGPoint(x: 17, y: 15.5))
        return path
    }()
}
