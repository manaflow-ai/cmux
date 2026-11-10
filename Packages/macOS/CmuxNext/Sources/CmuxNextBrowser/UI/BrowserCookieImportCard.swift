import AppKit
import CmuxNextDesign
import CmuxNextPages

/// A toast at the bottom of the page that offers to bring the person's
/// cookies over from another browser. Its line and answers are a React page
/// (webviews/src/browser-chrome/cookie-import, `BrowserChromeWebHost`): the
/// browser's icon, one line, Don't Show Again and Import as the toast's text
/// answers and its close button as Not Now (Leo 2026-11-08: "i dont like
/// this. 1. looks bad. 2. not glass. 3. talks about too much irrelevant
/// shit"). This view is the host only: the window's glass of the toast surface
/// (``SurfaceRole/toast``, the material the window's toasts draw on this same
/// overlay host), the popups' shadow, the card's size from the page's reports,
/// and the answers back to the chrome. It never takes focus (its window is
/// never key; the page takes the first click) and every answer closes it.
/// Under Reduce Transparency it is opaque (`OverlaySurfaceView`).
final class BrowserCookieImportCard: NSView {
    var onChoice: ((BrowserCookieImportChoice) -> Void)?
    /// The page measured a new height: the chrome places the card again.
    var onResize: (() -> Void)?
    /// The page measured its first state: the card may show (it waits at zero opacity until then,
    /// so it never shows empty or grows after it appeared).
    var onReady: (() -> Void)?
    /// Hidden while another tab of the pane shows; it shows again when this tab binds (`BrowserChromeTabSwitch`).
    weak var heldFor: BrowserChromeTabState?
    /// Off screen while its tab does not have the keyboard (``BrowserChromeTabState/hasKeyboard``): it
    /// floats on the window's overlay host, above every pane, so it must not show over the terminal,
    /// chat or Home the person is in (Lawrence 2026-11-07). Kept apart from `isHidden`, the pane's tab switch.
    var waitsForFocus = false
    /// Set while the close animation runs; a new offer then gets a new card.
    var isDismissing = false
    private(set) var offer: BrowserCookieImportOffer
    /// The card's material: glass, or opaque under Reduce Transparency.
    private(set) var glass: OverlaySurfaceView?
    /// The React page; nil when no page could be made (a test host without the page bundle).
    private(set) var content: (any BrowserChromeWebContent)?
    /// The state last pushed to the page (tests, diagnostics).
    private(set) var pushedState: [String: Any] = [:]
    /// Whether the page reported the size of the state it was given.
    private(set) var isMeasured = false
    private var height: NSLayoutConstraint?
    private let density = DensityBinding()
    /// Counts the states pushed; a report names the one it measured, so an older one is dropped.
    private var revision = 0

    /// - Parameter makeContent: Makes the card's React page; tests pass their own.
    init(offer: BrowserCookieImportOffer,
         makeContent: @MainActor () -> (any BrowserChromeWebContent)? = { BrowserChromeWebHost(.cookieImport) }) {
        self.offer = offer
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let body = NSView()
        let glass = Glass.makeSurface(.toast, content: body, cornerRadius: Self.cornerRadius)
        // It floats on the overlay host, a clear window over the page's own window. Liquid Glass there
        // has nothing in its own window to bend and drew a flat gray card with washed-out text (Lawrence
        // 2026-11-09, msg 26162); the frosted blur of the page behind the window is the dialog card's
        // material (`OverlayDialogCard`). Reduce Transparency keeps the opaque surface.
        glass.samplesBehindWindow = true
        glass.prefersBlurToLiquidGlass = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        castShadow()
        self.glass = glass
        // Until the page measures itself: one row.
        let height = heightAnchor.constraint(equalToConstant: Self.provisionalHeight)
        self.height = height
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
            density.bind(widthAnchor.constraint(lessThanOrEqualToConstant: 0)) { Self.maxWidth },
            // Preferred width: a pane narrower than it narrows the card.
            density.bind(widthAnchor.constraint(equalToConstant: 0).prioritized(.init(450))) { Self.maxWidth },
        ])
        density.start()
        if let made = makeContent() {
            made.onMessage = { [weak self] kind, params in self?.received(kind, params) }
            let page = made.view
            page.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                page.topAnchor.constraint(equalTo: body.topAnchor),
                page.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            ])
            content = made
        }
        setAccessibilityElement(false)
        applyColors()
        push()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The toast surface's radius.
    static var cornerRadius: CGFloat { SurfaceRole.toast.cornerRadius }
    /// Room for the line and the answers on one row in English (`toast` in the gallery): wider than
    /// the browser's prompts (`BrowserMetrics.promptMaxWidth`), whose text wraps.
    static var maxWidth: CGFloat { Metrics.paletteWidth * 7 / 8 }
    /// The height before the page's first report.
    static let provisionalHeight: CGFloat = 48
    /// The icon's side in pixels: the page draws it at 32 pt, so 2x stays sharp.
    static let iconPixels: CGFloat = 64

    /// The state the page draws (webviews/src/browser-chrome/cookie-import/model.ts).
    static func wireState(_ offer: BrowserCookieImportOffer, revision: Int, language: String) -> [String: Any] {
        var state: [String: Any] = [
            "title": offer.title, "importTitle": offer.importTitle, "notNowTitle": offer.notNowTitle,
            "revision": revision, "language": language,
        ]
        if let never = offer.neverTitle { state["neverTitle"] = never }
        if let icon = offer.icons.first.flatMap({ iconDataURL($0, pixels: iconPixels) }) { state["icon"] = icon }
        return state
    }

    /// `image` drawn into a square PNG of `pixels`, as a data URL; nil for an empty image.
    static func iconDataURL(_ image: NSImage, pixels: CGFloat) -> String? {
        guard image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(pixels), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    private func push() {
        revision += 1
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        pushedState = Self.wireState(offer, revision: revision, language: language)
        content?.push(pushedState)
    }

    /// A message from the page: an answer, or the height its content needs at the card's width.
    func received(_ kind: String, _ params: [String: Any]) {
        switch kind {
        case "command":
            guard !isDismissing, let choice = (params["type"] as? String).flatMap(BrowserCookieImportChoice.init(wire:)) else { return }
            onChoice?(choice)
        case "size":
            guard let reported = (params["height"] as? NSNumber)?.doubleValue, reported > 0,
                  (params["revision"] as? NSNumber)?.intValue == revision, let height else { return }
            let next = ceil(reported)
            let changed = height.constant != next
            height.constant = next
            if !isMeasured {
                isMeasured = true
                onReady?()
            } else if changed {
                onResize?()
            }
        default:
            break
        }
    }

    /// The card left the page for good: its page closes.
    func retire() {
        content?.close()
        content = nil
    }

    /// The popups' one subtle shadow, on this view's layer behind the glass
    /// (the glass clips to its corners, so it cannot cast its own).
    private func castShadow() {
        wantsLayer = true
        let elevation = PopupStyle.elevation2
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Float(elevation.alpha)
        layer?.shadowRadius = elevation.layerRadius
        layer?.shadowOffset = elevation.layerOffset()
    }

    override func layout() {
        super.layout()
        // CoreGraphics refuses a corner wider than half the rect.
        let radius = min(Self.cornerRadius, min(bounds.width, bounds.height) / 2)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme { glass?.applyTheme() }
    }

    /// The card's lines and buttons as shown (tests, diagnostics).
    var shownText: [String] {
        [offer.title] + (offer.neverTitle.map { [$0] } ?? []) + [offer.notNowTitle, offer.importTitle]
    }
}

extension BrowserCookieImportChoice {
    /// The page's name for the answer (`CookieImportChoice` in model.ts).
    init?(wire: String) {
        switch wire {
        case "import": self = .importCookies
        case "notNow": self = .notNow
        case "never": self = .never
        default: return nil
        }
    }
}
