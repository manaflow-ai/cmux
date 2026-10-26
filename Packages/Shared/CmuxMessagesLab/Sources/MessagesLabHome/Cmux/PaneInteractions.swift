import AppKit

/// MessagesLab 7f1a811's interaction parity (menu and picker chrome from
/// 69f4256 are in PaneMenu.swift) (Host.swift), for the pane
/// controller: press and hold on a message opens the tapback picker over a
/// dimmed pane (Esc or a click outside closes it), a double-click selects the
/// word under the cursor, and the context menu starts with the two tapback
/// palette rows. Host.swift is not vendored (it is MessagesLab's window
/// shell), so these are carried here with its values.
@MainActor
final class PressHold {
    /// Real Messages: the picker and the dim start 0.56-0.60 s after the press,
    /// about 0.09 s of that the capture path's latency.
    static let delay: TimeInterval = 0.5
    private var timer: Timer?
    /// What the hold runs when it fires (`start`'s `fire`), until `cancel`.
    private var action: (() -> Void)?
    private(set) var point: CGPoint?
    private(set) var fired = false

    func start(at p: CGPoint, _ fire: @escaping () -> Void) {
        cancel()
        point = p
        action = fire
        let t = Timer(timeInterval: Self.delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            // main-proof: the timer is added to RunLoop.main below, so it fires on the main thread.
            MainActor.assumeIsolated { self.timerFired() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func timerFired() {
        guard point != nil, let action else { return }
        fired = true
        action()
    }

    /// A drag of more than 3 pt is a selection, not a hold.
    func moved(to p: CGPoint) {
        if let start = point, hypot(p.x - start.x, p.y - start.y) > 3 { cancel() }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        action = nil
        point = nil
        fired = false
    }
}

/// The dim under the tapback picker (measured: every colour x0.46-0.51,
/// reached in about 0.17 s, ease-out); a click on it closes the picker.
///
/// The pressed bubble stays bright (real Messages lifts it): the dim has a hole in the
/// bubble's shape, so the real row shows through, upright and in its place. (A bitmap
/// copy of the row laid over the dim drew upside down in a cmux-next pane: its
/// orientation followed the flips of the views above it. Lawrence 2026-10-20.)
final class PickerDimView: NSView {
    static let opacity: Float = 0.52
    var onClick: (() -> Void)?
    /// The pressed bubble's outline in this view's coordinates (the host's: the dim covers its bounds).
    private let hole: CGPath?
    private let shade = CAShapeLayer()

    init(frame: NSRect, hole: CGPath? = nil) {
        self.hole = hole
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        shade.fillColor = NSColor.black.cgColor
        shade.fillRule = .evenOdd
        shade.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(shade)
        placeShade()
        layer?.opacity = Self.opacity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = Self.opacity
        fade.duration = 0.17
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(fade, forKey: "dim")
    }

    required init?(coder: NSCoder) { nil }

    /// Flipped as the host is, so the hole's host coordinates are this layer's (as MenuHighlight's
    /// path in the host's layer).
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        placeShade()
    }

    private func placeShade() {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole { path.addPath(hole) }
        shade.frame = bounds
        shade.path = path
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The context menu's tapback rows (real Messages, macOS 27): two inline
/// palettes at the top, the six tapbacks, then recent emoji and the emoji
/// picker.
@MainActor
enum TapbackMenuRows {
    /// The second row's emoji: the user's five most recent (MessagesLab 02519e9, `RecentEmoji`).
    static var recentEmoji: [String] { Array(RecentEmoji.list.prefix(5)) }

    static func items(current: Reaction.Kind?, react: @escaping (Reaction.Kind) -> Void, emojiPicker: @escaping () -> Void) -> [NSMenuItem] {
        func palette(_ entries: [(NSImage, String, Reaction.Kind?)]) -> NSMenuItem {
            let pal = NSMenu()
            pal.presentationStyle = .palette
            for (img, title, kind) in entries {
                let it = MenuAction(title: title) { if let kind { react(kind) } else { emojiPicker() } }
                it.image = img
                if let kind, current == kind { it.state = .on }
                pal.addItem(it)
            }
            let item = NSMenuItem()
            item.submenu = pal
            return item
        }
        return [
            // MessagesLab ced183d: Messages' own tapback art (drawn glyphs as the fallback), 20 pt
            // palette images, fitted emoji and face sizes (MenuGlyphs.swift).
            palette(TapbackGlyph.all.map { (MenuGlyphs.image(.tapback($0)), Strings.tapbackName($0), Reaction.Kind.tapback($0)) }),
            palette(recentEmoji.map { (MenuGlyphs.image(.emoji($0)), $0, Reaction.Kind.emoji($0)) }
                    + [(MenuGlyphs.emojiPickerGlyph(), Strings.menuTapback, nil)]),
        ]
    }
}

/// The person's recently used emoji reactions, most recent first (MessagesLab
/// 02519e9 Host.swift, not vendored): the context menu's second palette row
/// shows the first five, the tapback picker strip the first two after its six
/// tapbacks. Real Messages keeps one such list. An emoji reaction moves its
/// emoji to the front. cmux: no `--recent-emoji` argument (a MessagesLab take's scene).
/// Main actor: the menu, the picker strip and the projection's tapback read and write it there.
@MainActor
enum RecentEmoji {
    static let defaults = ["\u{1F602}", "\u{2764}\u{FE0F}", "\u{1F60D}", "\u{1F612}", "\u{1F44C}"]
    private(set) static var list: [String] = defaults
    static func use(_ e: String) {
        list.removeAll { $0 == e }
        list.insert(e, at: 0)
        if list.count > 16 { list.removeLast(list.count - 16) }
    }
}
