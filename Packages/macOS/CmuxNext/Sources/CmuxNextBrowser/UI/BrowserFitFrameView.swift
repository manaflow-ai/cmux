public import AppKit
import CmuxNextDesign

/// A command from the fit bar: fits go to the App (`BrowserFitFrameView.perform`), zoom to the page's chrome.
nonisolated enum BrowserFitCommand: Sendable, Equatable {
    /// Another fit ("16:10", "1440"...), or nil to turn the fit off.
    case fit(String?)
    /// Ask for a custom aspect ratio or width (the palette's argument page).
    case custom
    /// Page zoom: +1 in, -1 out, 0 actual size (the frame runs it on its own browser chrome).
    case zoom(Int)
}

/// The frame around a page that a fit shows (cx-qby5j), drawn under the page
/// in the page's container (WebKit's container, CEF's tab content view): a
/// quiet backdrop, a hairline on the emulated viewport's bounds, and one bar
/// under it that says what is happening ("Desktop 1556 × 2397 at 37%"), with
/// the fit choices, zoom and Turn Off. The first bar of an app run also shows
/// one muted line that explains the mode, once ever on this Mac (cx-d077f):
/// the first bar that shows it records that in UserDefaults (as the tips card
/// records seen tips), keeps it until the bar is used, and the status label's
/// tooltip keeps the same sentence afterwards.
public final class BrowserFitFrameView: NSView {
    /// Sets a daemon tab's fit (set by the App): a value ("16:10", "1440", "off"), or nil to ask for one.
    @MainActor public static var perform: (@MainActor (_ tab: String, _ fit: String?) -> Void)?
    /// The explanation line still shows (until the first use of a bar in this app run).
    @MainActor private static var explains = !UserDefaults.standard.bool(forKey: explainedKey)
    /// Set once the explanation was on screen.
    static let explainedKey = "cmux.next.browser.fitExplained"

    /// The fits the bar offers: aspect ratios at the pane's height, then fixed widths.
    static let aspects = ["16:9", "16:10", "4:3", "21:9"]
    static let widths = ["1280", "1440", "1920"]

    private var presented: CGRect = .zero
    private var tabID: String?
    private var value = ""
    private let label = ChromeLabel(labelWithString: "")
    private let note = ChromeLabel(labelWithString: Strings.explain)
    private let choose = NSButton(title: "", target: nil, action: nil)
    private let off = NSButton(title: Strings.turnOff, target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for field in [label, note] {
            field.font = .systemFont(ofSize: TypeScale.caption)
            field.lineBreakMode = .byTruncatingTail
        }
        label.themedToolTip = Strings.explain
        for button in [choose, off] {
            button.isBordered = false
            button.target = self
            button.font = .systemFont(ofSize: TypeScale.caption, weight: TypeScale.emphasis)
        }
        choose.action = #selector(showChoices)
        choose.imagePosition = .imageTrailing
        // chrome-icons: allow the device-frame picker's pop-up chevron, not browser chrome
        choose.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        off.action = #selector(turnOff)
        for view in [label, note, choose, off] { addSubview(view) }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { false }

    /// The fit, where its page shows (this view's coordinates) and the page's layout size and scale.
    func update(emulation: BrowserEmulation?, presented: CGRect, layout: CGSize, scale: CGFloat) {
        let percent = Int((scale * 100).rounded())
        let text = Strings.status(width: Int(layout.width), height: Int(layout.height), percent: percent)
        let changed = presented != self.presented || text != label.stringValue || value != (emulation?.fit?.value ?? "")
        self.presented = presented
        tabID = emulation?.tabID
        value = emulation?.fit?.value ?? ""
        label.stringValue = text
        note.isHidden = !Self.explains
        if Self.explains, !UserDefaults.standard.bool(forKey: Self.explainedKey) {
            UserDefaults.standard.set(true, forKey: Self.explainedKey) // shown now: never in a later app run
        }
        let title = Strings.title(value)
        if choose.attributedTitle.string != title {
            // Set as an attributed title every time it differs (a plain title would drop the muted color).
            choose.title = title
            applyColors()
            needsLayout = true
        }
        if changed {
            applyColors()
            needsDisplay = true
        }
        layoutBar()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        needsDisplay = true
    }

    private func applyColors() {
        performWithTheme {
            label.textColor = Palette.textSecondary
            note.textColor = Palette.textTertiary
            for button in [choose, off] {
                button.contentTintColor = Palette.textSecondary
                button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                    .foregroundColor: Palette.textSecondary, .font: NSFont.systemFont(ofSize: TypeScale.caption, weight: TypeScale.emphasis),
                ])
            }
        }
    }

    override public func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            Palette.chromeBackground.setFill()
            bounds.fill()
            guard presented.width > 0, presented.height > 0 else { return }
            Palette.separator.setStroke()
            let edge = NSBezierPath(rect: presented.insetBy(dx: -0.5, dy: -0.5))
            edge.lineWidth = 1
            edge.stroke()
        }
    }

    override public func layout() {
        super.layout()
        layoutBar()
    }

    /// The bar in the strip under the page, centered on the page: status, explanation, fit menu, Turn Off.
    /// In a narrow pane the explanation shrinks first (hidden under 60 pt), then the status; the controls keep their size.
    private func layoutBar() {
        let strip = CGRect(x: bounds.minX + 8, y: bounds.minY, width: max(0, bounds.width - 16), height: max(0, presented.minY - bounds.minY))
        let spacing: CGFloat = 10
        label.sizeToFit()
        note.sizeToFit()
        for control in [choose, off] { control.sizeToFit() }
        let controls = choose.frame.width + off.frame.width + spacing
        let labelWidth = max(0, min(label.frame.width, strip.width - controls - spacing))
        var noteWidth = !Self.explains ? 0 : min(note.frame.width, strip.width - controls - labelWidth - 2 * spacing)
        if noteWidth < 60 { noteWidth = 0 }
        let pieces: [(NSView, CGFloat)] = [(label, labelWidth), (note, noteWidth), (choose, choose.frame.width), (off, off.frame.width)]
        let total = pieces.filter { $0.1 > 0 }.reduce(-spacing) { $0 + $1.1 + spacing }
        let center = presented.width > 0 ? presented.midX : strip.midX
        var x = min(max(strip.minX, center - total / 2), max(strip.minX, strip.maxX - total))
        for (view, width) in pieces {
            view.isHidden = width <= 0 || (view === note && !Self.explains)
            guard width > 0 else { continue }
            let height = view.frame.height
            view.frame = CGRect(x: x.rounded(), y: (strip.midY - height / 2).rounded(), width: width, height: height)
            x += width + spacing
        }
    }

    // MARK: Commands

    @objc private func showChoices() {
        Self.explains = false
        note.isHidden = true
        needsLayout = true
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: Strings.aspectRatio))
        for aspect in Self.aspects { add(Strings.title(aspect), .fit(aspect), checked: aspect == value, to: menu) }
        menu.addItem(.sectionHeader(title: Strings.width))
        for width in Self.widths { add(Strings.title(width), .fit(width), checked: width == value, to: menu) }
        let known = Self.aspects + Self.widths
        add(known.contains(value) ? Strings.custom : Strings.customCurrent(value), .custom, checked: !known.contains(value), to: menu)
        menu.addItem(.separator())
        add(Strings.zoomIn, .zoom(1), to: menu)
        add(Strings.zoomOut, .zoom(-1), to: menu)
        add(Strings.actualSize, .zoom(0), to: menu)
        menu.addItem(.separator())
        add(Strings.turnOff, .fit(nil), to: menu)
        // Upward: the bar is at the bottom of the pane.
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: choose.bounds.minY - 4), in: choose)
    }

    @objc private func turnOff() { run(.fit(nil)) }

    @objc private func pick(_ item: NSMenuItem) {
        guard let command = (item.representedObject as? Box)?.command else { return }
        run(command)
    }

    private func run(_ command: BrowserFitCommand) {
        Self.explains = false
        note.isHidden = true
        needsLayout = true
        if case .zoom(let step) = command {
            // Page zoom of the tab this frame belongs to, as its toolbar's zoom does.
            var view = superview
            while let current = view, !(current is BrowserChromeView) { view = current.superview }
            (view as? BrowserChromeView)?.perform(step > 0 ? .zoomIn : step < 0 ? .zoomOut : .resetZoom)
            return
        }
        guard let tabID else { return }
        switch command {
        case .fit(let value): Self.perform?(tabID, value ?? "off")
        case .custom: Self.perform?(tabID, nil)
        case .zoom: break
        }
    }

    private func add(_ title: String, _ command: BrowserFitCommand, checked: Bool = false, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Box(command)
        item.state = checked ? .on : .off
        menu.addItem(item)
    }

    private final class Box: NSObject {
        let command: BrowserFitCommand
        init(_ command: BrowserFitCommand) { self.command = command }
    }

    /// The bar's text (BrowserDevices.xcstrings).
    nonisolated enum Strings {
        static func status(width: Int, height: Int, percent: Int) -> String {
            String(localized: "browserDevices.fit.status", defaultValue: "Desktop \(width) × \(height) at \(percent)%",
                   table: "BrowserDevices", bundle: .module)
        }

        static var explain: String {
            String(localized: "browserDevices.fit.explain", defaultValue: "The page lays out as a desktop and is scaled to fit this pane.",
                   table: "BrowserDevices", bundle: .module)
        }

        static var turnOff: String { String(localized: "browserDevices.fit.turnOff", defaultValue: "Turn Off", table: "BrowserDevices", bundle: .module) }
        static var aspectRatio: String {
            String(localized: "browserDevices.fit.aspectRatio", defaultValue: "Aspect Ratio", table: "BrowserDevices", bundle: .module)
        }
        static var width: String { String(localized: "browserDevices.fit.width", defaultValue: "Width", table: "BrowserDevices", bundle: .module) }
        static var custom: String { String(localized: "browserDevices.fit.custom", defaultValue: "Custom…", table: "BrowserDevices", bundle: .module) }
        static func customCurrent(_ value: String) -> String {
            String(localized: "browserDevices.fit.customCurrent", defaultValue: "Custom (\(value))…", table: "BrowserDevices", bundle: .module)
        }
        static var zoomIn: String { String(localized: "browserDevices.fit.zoomIn", defaultValue: "Zoom In", table: "BrowserDevices", bundle: .module) }
        static var zoomOut: String { String(localized: "browserDevices.fit.zoomOut", defaultValue: "Zoom Out", table: "BrowserDevices", bundle: .module) }
        static var actualSize: String {
            String(localized: "browserDevices.fit.actualSize", defaultValue: "Actual Size", table: "BrowserDevices", bundle: .module)
        }

        /// A fit as the bar names it: an aspect ratio as is ("16:10"), a width with its unit ("1440 px").
        static func title(_ value: String) -> String {
            guard let width = Int(value) else { return value }
            return String(localized: "browserDevices.fit.widthValue", defaultValue: "\(width) px", table: "BrowserDevices", bundle: .module)
        }
    }
}
