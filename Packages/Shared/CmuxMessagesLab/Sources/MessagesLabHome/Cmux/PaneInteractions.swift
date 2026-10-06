import AppKit

/// MessagesLab 7f1a811's interaction parity (Host.swift), for the pane
/// controller: press and hold on a message opens the tapback picker over a
/// dimmed pane (Esc or a click outside closes it), a double-click selects the
/// word under the cursor, and the context menu starts with the two tapback
/// palette rows. Host.swift is not vendored (it is MessagesLab's window
/// shell), so these are carried here with its values.
final class PressHold {
    /// Real Messages: the picker and the dim start 0.56-0.60 s after the press,
    /// about 0.09 s of that the capture path's latency.
    static let delay: TimeInterval = 0.5
    private var timer: Timer?
    private(set) var point: CGPoint?
    private(set) var fired = false

    func start(at p: CGPoint, _ fire: @escaping () -> Void) {
        cancel()
        point = p
        let t = Timer(timeInterval: Self.delay, repeats: false) { [weak self] _ in
            guard let self, self.point != nil else { return }
            self.fired = true
            fire()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// A drag of more than 3 pt is a selection, not a hold.
    func moved(to p: CGPoint) {
        if let start = point, hypot(p.x - start.x, p.y - start.y) > 3 { cancel() }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        point = nil
        fired = false
    }
}

/// The dim under the tapback picker (measured: every colour x0.46-0.51,
/// reached in about 0.17 s, ease-out); a click on it closes the picker.
final class PickerDimView: NSView {
    static let opacity: Float = 0.52
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.opacity = Self.opacity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = Self.opacity
        fade.duration = 0.17
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(fade, forKey: "dim")
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The context menu's tapback rows (real Messages, macOS 27): two inline
/// palettes at the top, the six tapbacks, then recent emoji and the emoji
/// picker.
enum TapbackMenuRows {
    /// The second row's emoji (the real app shows the user's recent ones).
    static let recentEmoji = ["\u{1F440}", "\u{2705}", "\u{1F602}", "\u{2764}\u{FE0F}", "\u{1F60D}"]

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
            palette(TapbackGlyph.all.map { (TapbackPickerView.glyph($0, on: false), Strings.tapbackName($0), Reaction.Kind.tapback($0)) }),
            palette(recentEmoji.map { (emojiImage($0), $0, Reaction.Kind.emoji($0)) }
                    + [(NSImage(systemSymbolName: "face.smiling.inverse", accessibilityDescription: nil) ?? NSImage(), Strings.menuTapback, nil)]),
        ]
    }

    static func emojiImage(_ e: String) -> NSImage {
        NSImage(size: NSSize(width: TapbackPickerView.item, height: TapbackPickerView.item), flipped: true) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            PartRenderer.drawEmoji(e, in: r.insetBy(dx: 7, dy: 7), ctx: ctx)
            return true
        }
    }
}
