import AppKit
import CmuxNextDesign
import QuartzCore

/// The agent driving the screen (Computer Use) or a browser in a workspace, on its row
/// (Lawrence 2026-11-07): what it drives as a glyph, in the agent's presence color
/// (`AgentPresenceColor`, the same color as its tab chip and pane tag), drawn as
/// ``SidebarDriveIndicatorVariant`` says. The tooltip and the accessibility label say who drives
/// what; a click opens Go to (the agent's tab) and Stop.
///
/// Motion: the glyph breathes slowly (agent work's breath, `MotionLoop.breath`) while the agent
/// drives, so the row reads as live without pulling the eye like a spinner; it appears with the
/// short ease-out `fadeIn`. Under Reduce Motion both are off and the indicator shows at once, at full
/// strength.
final class AgentDriveIndicatorView: ClickableButton {
    /// The glyph's opacity at the bottom of a breath: low enough to see, high enough to stay legible.
    static let breathFloor: Float = 0.5
    static let glyphSide: CGFloat = 11

    /// The driving agents, first shown; the rest count in the tooltip.
    private(set) var drivers: [SidebarPresence] = []
    private(set) var variant: SidebarDriveIndicatorVariant = .capsule
    /// Makes the menu's Go to and Stop rows, titled as given, from registered actions
    /// (``SidebarView/driveMenuItem``); nil, or nil for a row, leaves the row out.
    var makeItem: ((SidebarDriveCommand, _ title: String) -> NSMenuItem?)?

    private let fill = CALayer()
    private let glyph = CALayer()
    private let nameLabel = SidebarRowView.label(font: SidebarStyle.subtitleFont)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title = ""
        isBordered = false
        imagePosition = .noImage
        refusesFirstResponder = true
        focusRingType = .none
        target = self
        action = #selector(pressed)
        for sub in [fill, glyph] {
            sub.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "contents": NSNull()]
            layer?.addSublayer(sub)
        }
        fill.cornerCurve = .continuous
        glyph.contentsGravity = .resizeAspect
        addSubview(nameLabel)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }

    /// The agent the indicator draws: the first driver.
    var shown: SidebarPresence? { drivers.first }

    /// Shows `drivers` (only the presence entries that drive something) as `variant`.
    func configure(_ drivers: [SidebarPresence], variant: SidebarDriveIndicatorVariant) {
        let drivers = drivers.filter { $0.drive != nil }
        guard drivers != self.drivers || variant != self.variant else { return }
        let wasHidden = self.drivers.isEmpty
        self.drivers = drivers
        self.variant = variant
        isHidden = drivers.isEmpty
        nameLabel.setString(variant == .capsule ? shown.map { Self.shortName($0.name) } ?? "" : "")
        nameLabel.isHidden = variant != .capsule
        let summary = drivers.map(Strings.presenceLine).joined(separator: "\n")
        themedToolTip = drivers.isEmpty ? nil : summary + "\n" + Strings.driveClickHint
        setAccessibilityLabel(drivers.isEmpty ? nil : summary)
        setAccessibilityRole(.button)
        needsLayout = true
        needsDisplay = true
        if drivers.isEmpty {
            glyph.removeAllAnimations()
        } else {
            if wasHidden { appear() }
            breathe()
        }
    }

    /// The width the indicator takes for its look.
    var preferredWidth: CGFloat {
        guard shown != nil else { return 0 }
        switch variant {
        case .capsule: return ceil(Metrics.space1 * 1.5 + Self.glyphSide + Metrics.space1 + nameLabel.naturalSize.width + Metrics.space1 * 1.5)
        case .glyph: return Self.glyphSide + 2
        case .badge: return Self.glyphSide + 6
        case .dot: return SidebarStyle.dotSize
        }
    }

    /// The indicator's height for its look (the capsule is a label tall; the others a glyph).
    var preferredHeight: CGFloat {
        switch variant {
        case .capsule: max(Self.glyphSide + 5, ceil(nameLabel.naturalSize.height) + 2)
        case .glyph: Self.glyphSide + 2
        case .badge: Self.glyphSide + 6
        case .dot: SidebarStyle.dotSize
        }
    }

    /// `Claude Code 2` draws as `Claude 2`: the first word and its number, so the capsule stays short.
    static func shortName(_ name: String) -> String {
        let words = name.split(separator: " ")
        guard let first = words.first else { return name }
        if words.count > 1, let last = words.last, Int(last) != nil { return "\(first) \(last)" }
        return String(first)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let b = bounds, g = Self.glyphSide
        switch variant {
        case .capsule:
            fill.frame = b
            fill.cornerRadius = b.height / 2
            glyph.frame = CGRect(x: Metrics.space1 * 1.5, y: (b.height - g) / 2, width: g, height: g)
            let size = nameLabel.naturalSize
            nameLabel.frame = NSRect(x: glyph.frame.maxX + Metrics.space1, y: (b.height - ceil(size.height)) / 2,
                                     width: max(0, b.width - glyph.frame.maxX - Metrics.space1 * 2.5), height: ceil(size.height))
        case .glyph:
            fill.frame = .zero
            glyph.frame = CGRect(x: (b.width - g) / 2, y: (b.height - g) / 2, width: g, height: g)
        case .badge:
            let d = min(b.width, b.height)
            fill.frame = CGRect(x: (b.width - d) / 2, y: (b.height - d) / 2, width: d, height: d)
            fill.cornerRadius = d / 2
            let inner = g - 3
            glyph.frame = CGRect(x: (b.width - inner) / 2, y: (b.height - inner) / 2, width: inner, height: inner)
        case .dot:
            let d = SidebarStyle.dotSize
            // Width equals height and the radius is half of it: a true circle.
            fill.frame = CGRect(x: (b.width - d) / 2, y: (b.height - d) / 2, width: d, height: d)
            fill.cornerRadius = d / 2
            glyph.frame = .zero
        }
    }

    override func updateLayer() {
        guard let shown, let drive = shown.drive else { return }
        performWithTheme {
            let agent = AgentPresenceColor(key: shown.id)
            let color = agent.color
            let scale = window?.backingScaleFactor ?? 2
            switch variant {
            case .capsule:
                fill.backgroundColor = color.withAlphaComponent(0.16).cgColor
                glyph.contents = Self.symbol(drive, color: color, scale: scale)
                nameLabel.setColor(color)
            case .glyph:
                fill.backgroundColor = nil
                glyph.contents = Self.symbol(drive, color: color, scale: scale)
            case .badge:
                fill.backgroundColor = color.cgColor
                glyph.contents = Self.symbol(drive, color: agent.ink, scale: scale)
            case .dot:
                fill.backgroundColor = color.cgColor
                glyph.contents = nil
            }
            glyph.contentsScale = scale
        }
    }

    /// `drive`'s SF Symbol in `color`, rendered for `scale`.
    static func symbol(_ drive: SidebarDriveKind, color: NSColor, scale: CGFloat) -> Any? {
        let config = NSImage.SymbolConfiguration(pointSize: glyphSide, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: drive.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        return image?.layerContents(forContentsScale: scale)
    }

    /// The slow breath while the agent drives: agent work's breath (`MotionLoop.breath`, the working dot's),
    /// so every live agent mark breathes alike; none under Reduce Motion, where the glyph rests at full strength.
    private func breathe() {
        let breathing = variant != .dot ? glyph : fill
        (variant != .dot ? fill : glyph).removeAnimation(forKey: "breath")
        guard let breath = Motion.indicators.breathAnimation(low: Self.breathFloor) else {
            breathing.removeAnimation(forKey: "breath")
            return
        }
        guard breathing.animation(forKey: "breath") == nil else { return }
        breathing.add(breath, forKey: "breath")
    }

    /// Fades in on the `fadeIn` token (an element entering: short, ease-out); instant under Reduce Motion.
    private func appear() {
        guard let layer else { return }
        _ = Motion.sidebar.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
    }

    @objc private func pressed() {
        guard let shown else { return }
        menu(for: shown).popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + Metrics.space1), in: self)
    }

    /// Go to the agent's tab, then Stop when the row can stop what it drives; one pair per driver.
    func menu(for first: SidebarPresence) -> NSMenu {
        let menu = NSMenu()
        // The registry's rows enable as their actions can run now; a header has no action and stays off.
        menu.autoenablesItems = true
        for driver in drivers {
            guard let tab = driver.tab else { continue }
            if drivers.count > 1 {
                menu.addItem(NSMenuItem(title: Strings.presenceLine(driver), action: nil, keyEquivalent: ""))
            }
            add(.goTo(tab: tab), Strings.driveGoTo(driver.name), symbol: "arrow.right.circle", to: menu)
            if driver.canStop, let drive = driver.drive {
                add(.stop(tab: tab, drive: drive), Strings.driveStop(drive), symbol: "stop.circle", to: menu)
            }
            if driver != drivers.last { menu.addItem(.separator()) }
        }
        return menu
    }

    private func add(_ command: SidebarDriveCommand, _ title: String, symbol: String, to menu: NSMenu) {
        guard let item = makeItem?(command, title) else { return }
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Core Animation drops a layer's animations when it leaves the window; the breath comes back with it.
        if window != nil, !drivers.isEmpty { breathe() }
    }
}
