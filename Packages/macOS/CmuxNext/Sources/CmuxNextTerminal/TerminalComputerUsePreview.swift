public import AppKit
import CmuxNextDesign
import CmuxNextIcons
import ImageIO

/// The live preview card of Computer Use in a terminal pane, the native twin of the agent chat's
/// card (webviews `ComputerUsePreviewCard.tsx`): while the agent running in this terminal drives an
/// app, a live view of that app's window at the pane's top-trailing corner, the agent's cursor
/// drawn where it acts; when its Computer Use ends, the last frame dims under a green check.
/// A click on the card enlarges it (and back); the close button hides it for that session.
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

        public init(session: String, app: String, done: Bool, frame: String, pointer: CGPoint? = nil, clicks: Int = 0) {
            self.session = session
            self.app = app
            self.done = done
            self.frame = frame
            self.pointer = pointer
            self.clicks = clicks
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
            self.init(session: session, app: json["app"] as? String ?? "", done: json["done"] as? Bool ?? false,
                      frame: frame, pointer: pointer, clicks: clicks)
        }
    }

    /// The small card's width; the enlarged one takes up to ``expandedFraction`` of the pane.
    public static let width: CGFloat = 180
    public static let expandedWidth: CGFloat = 560
    public static let expandedFraction: CGFloat = 0.6

    /// The person closed it: the App hides this session's card from now on.
    public var onClose: (@MainActor (_ session: String) -> Void)?
    /// The card shown, nil while none.
    public private(set) var card: Card?
    public private(set) var expanded = false
    /// The width of the pane the card sits in (the host sets it on layout).
    var paneWidth: CGFloat = 800 { didSet { if oldValue != paneWidth { invalidateIntrinsicContentSize() } } }

    private let frameLayer = CALayer()
    private let dim = CALayer()
    private let cursor = CAShapeLayer()
    private let badge = CAShapeLayer()
    private let checkmark = CAShapeLayer()
    private let closeButton = NSButton()
    private var aspect: CGFloat = 0.625
    private var decoding: String?
    private static let decoder = DispatchQueue(label: "terminal-cu-preview-decode", qos: .userInitiated)

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
        cursor.fillColor = NSColor(srgbRed: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255, alpha: 1).cgColor
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
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 9
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.setAccessibilityLabel(String(localized: "terminal.computerUsePreview.close", defaultValue: "Hide Preview", bundle: .module))
        addSubview(closeButton)
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
            expanded = false
            frameLayer.contents = nil
            decoding = nil
            superview?.needsLayout = true
            return
        }
        if previous?.session != card.session { expanded = false }
        setAccessibilityLabel(Self.label(card))
        if card.frame != previous?.frame { decode(card.frame) }
        if previous?.done != card.done || previous?.pointer != card.pointer { layoutContents() }
        if isHidden, frameLayer.contents != nil { isHidden = false }
    }

    private func decode(_ url: String) {
        decoding = url
        Self.decoder.async { [weak self] in
            let image = Self.image(fromDataURL: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
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
        }
    }

    nonisolated static func image(fromDataURL url: String) -> CGImage? {
        guard let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public override var intrinsicContentSize: NSSize {
        let width = expanded ? min(Self.expandedWidth, max(Self.width, paneWidth * Self.expandedFraction)) : Self.width
        return NSSize(width: width, height: (width * aspect).rounded())
    }

    public override var fittingSize: NSSize { intrinsicContentSize }

    public override func layout() {
        super.layout()
        layoutContents()
    }

    private func layoutContents() {
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
        performWithTheme {
            frameLayer.borderColor = Palette.separator.cgColor
            closeButton.layer?.backgroundColor = Palette.elevatedBackground.cgColor
        }
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Taken here, so the click never reaches the terminal under the card.
    public override func mouseDown(with event: NSEvent) {}

    public override func mouseUp(with event: NSEvent) {
        guard card != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        toggleExpanded()
    }

    public override func accessibilityPerformPress() -> Bool {
        toggleExpanded()
        return true
    }

    /// The small card enlarges, the large one shrinks back.
    public func toggleExpanded() {
        expanded.toggle()
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    @objc private func close() {
        guard let session = card?.session else { return }
        show(nil)
        onClose?(session)
    }

    private static func label(_ card: Card) -> String {
        let app = card.app.trimmingCharacters(in: .whitespaces)
        if card.done {
            return app.isEmpty
                ? String(localized: "terminal.computerUsePreview.doneNoApp", defaultValue: "App preview, done", bundle: .module)
                : String(localized: "terminal.computerUsePreview.done", defaultValue: "\(app), done", bundle: .module)
        }
        return app.isEmpty
            ? String(localized: "terminal.computerUsePreview.runningNoApp", defaultValue: "Live app preview", bundle: .module)
            : String(localized: "terminal.computerUsePreview.running", defaultValue: "\(app), live", bundle: .module)
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
