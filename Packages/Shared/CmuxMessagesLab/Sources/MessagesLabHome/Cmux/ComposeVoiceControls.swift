// cmux: the message box's voice controls (Leo's spec, 2026-10-20). Not a vendored file.
import AppKit

/// The voice controls on the field's last line, right-aligned in its trailing slot.
///
/// At rest: the mic button alone, where Messages draws its decorative waveform, shown while the
/// field is empty (text or an attachment turns the slot into the send button). While a session
/// runs the slot widens (``listeningWidth``) and shows, left to right: a live waveform of thin
/// bars that fade to dots at both ends, the return-key button that finishes and keeps the words,
/// and the mic button, highlighted in the theme's accent, which stops it too.
final class ComposeVoiceControls: NSView {
    var onMic: () -> Void = {}
    var onFinish: () -> Void = {}

    let mic = ComposeVoiceButton(symbol: "mic", activeSymbol: "mic.fill")
    let finish = ComposeVoiceButton(symbol: "return", activeSymbol: "return")
    let wave = ComposeVoiceWave()
    private(set) var isListening = false

    /// The trailing width the text leaves free while a session runs.
    static let listeningWidth: CGFloat = 4 + ComposeVoiceWave.width + 6 + ComposeSendSlot.target * 2 + 2
    /// The controls' height (the send button's hit target, centred on the last line).
    static let height: CGFloat = ComposeSendSlot.target

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for v: NSView in [wave, finish, mic] { addSubview(v) }
        mic.onPress = { [weak self] in self?.onMic() }
        finish.onPress = { [weak self] in self?.onFinish() }
        mic.setAccessibilityIdentifier("cmux.home.composer.mic")
        finish.setAccessibilityIdentifier("cmux.home.composer.finishDictation")
        setListening(false)
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// The controls' frame for the field `f` (the pane's coordinates, y down): the mic's centre is the
    /// send button's (`ComposeSendSlot`), the rest extends to its left.
    static func frame(field f: CGRect, listening: Bool) -> CGRect {
        let w = listening ? listeningWidth - 4 : ComposeSendSlot.target
        let centre = CGPoint(x: f.maxX - ComposeSendSlot.centreFromRight, y: f.maxY - ComposeSendSlot.centreFromBottom)
        let right = centre.x + ComposeSendSlot.target / 2
        return CGRect(x: right - w, y: centre.y - height / 2, width: w, height: height)
    }

    override func layout() {
        super.layout()
        let t = ComposeSendSlot.target
        mic.frame = CGRect(x: bounds.width - t, y: 0, width: t, height: t)
        finish.frame = CGRect(x: bounds.width - 2 * t - 2, y: 0, width: t, height: t)
        wave.frame = CGRect(x: 0, y: (t - ComposeVoiceWave.height) / 2, width: ComposeVoiceWave.width, height: ComposeVoiceWave.height)
    }

    /// Idle (the mic alone) or a running session (waveform, finish, the highlighted mic).
    func setListening(_ listening: Bool) {
        isListening = listening
        wave.isHidden = !listening
        finish.isHidden = !listening
        mic.isActive = listening
        let label = listening ? CmuxStrings.stopDictation : CmuxStrings.dictate
        mic.setAccessibilityLabel(label)
        mic.toolTip = label
        finish.setAccessibilityLabel(CmuxStrings.finishDictation)
        finish.toolTip = CmuxStrings.finishDictation
        needsLayout = true
    }

    private var applied: (ink: NSColor, accent: NSColor, appearance: NSAppearance.Name)?

    /// The theme's inks: the glyphs' resting colour and the accent. Unchanged inks in the same
    /// appearance touch nothing (this runs with every draft change).
    func applyColors(ink: NSColor, accent: NSColor) {
        let appearance = effectiveAppearance.name
        if let applied, applied.ink == ink, applied.accent == accent, applied.appearance == appearance { return }
        applied = (ink, accent, appearance)
        mic.applyColors(ink: ink, accent: accent)
        finish.applyColors(ink: ink, accent: ink)
        wave.ink = ink
        wave.accent = accent
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let p = convert(point, from: superview)
        for b in [mic, finish] where !b.isHidden && b.frame.contains(p) { return b }
        return nil
    }
}

/// One round glyph button of the voice controls (the mic, the return key). Active: the accent
/// rounded square behind an accent glyph (the mic while it records).
final class ComposeVoiceButton: NSView {
    var onPress: () -> Void = {}
    private let glyph = NSImageView()
    private let backing = CALayer()
    private let symbol: String
    private let activeSymbol: String
    private var ink: NSColor = .secondaryLabelColor
    private var accent: NSColor = .controlAccentColor
    private var pressing = false
    /// The symbol the glyph shows now (its image is made only when this changes).
    private var shownSymbol: String?
    var isActive = false { didSet { if isActive != oldValue { applyLook() } } }

    init(symbol: String, activeSymbol: String) {
        self.symbol = symbol
        self.activeSymbol = activeSymbol
        super.init(frame: NSRect(x: 0, y: 0, width: ComposeSendSlot.target, height: ComposeSendSlot.target))
        wantsLayer = true
        backing.actions = ["backgroundColor": NSNull(), "opacity": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        backing.cornerRadius = 7
        backing.cornerCurve = .continuous
        layer?.addSublayer(backing)
        glyph.imageScaling = .scaleNone
        addSubview(glyph)
        setAccessibilityRole(.button)
        setAccessibilityElement(true)
        applyLook()
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func layout() {
        super.layout()
        glyph.frame = bounds
        backing.frame = bounds.insetBy(dx: 1, dy: 1)
    }

    func applyColors(ink: NSColor, accent: NSColor) {
        self.ink = ink
        self.accent = accent
        applyLook()
    }

    private func applyLook() {
        let name = isActive ? activeSymbol : symbol
        if name != shownSymbol {
            shownSymbol = name
            glyph.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(FieldChrome.glyphConfig)
        }
        glyph.contentTintColor = isActive ? accent : ink
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backing.backgroundColor = accent.withAlphaComponent(0.22).cgColor
        backing.opacity = isActive ? 1 : 0
        layer?.opacity = pressing ? 0.6 : 1
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { pressing = true; applyLook() }
    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != pressing { pressing = inside; applyLook() }
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressing = false; applyLook()
        if inside { onPress() }
    }
    override func accessibilityPerformPress() -> Bool { onPress(); return true }
}

/// The live waveform: thin vertical bars whose height follows the input level, falling to dots at
/// both ends. Each level moves the bars in one frame (no animation object); with the gate off
/// (Reduce Motion, animations off) the bars stand still, tinted the accent while listening.
final class ComposeVoiceWave: NSView {
    static let bars = 19
    static let pitch: CGFloat = 4
    static let barWidth: CGFloat = 1.6
    static let width: CGFloat = CGFloat(bars - 1) * pitch + barWidth
    static let height: CGFloat = 20
    /// Whether the bars move with the level (the host's motion gate; MessagesLabHomeView.voiceMotionGate).
    var moves: () -> Bool = { MessagesLabHomeView.voiceMotionGate() }
    // Set only when an ink or the appearance changed (`ComposeVoiceControls.applyColors`).
    var ink: NSColor = .secondaryLabelColor { didSet { recolor() } }
    var accent: NSColor = .controlAccentColor { didSet { recolor() } }
    private var layers: [CALayer] = []
    /// A step through the bars' jitter so a steady level still looks alive.
    private var phase = 0
    private(set) var heights: [CGFloat] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<Self.bars {
            let l = CALayer()
            l.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "backgroundColor": NSNull()]
            l.cornerRadius = Self.barWidth / 2
            layer?.addSublayer(l)
            layers.append(l)
        }
        setAccessibilityElement(false)
        show(level: 0)
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// The bar's share of the level: zero for the three dots at each end, a bell between them.
    static func weight(_ i: Int) -> CGFloat {
        let edge = 3
        guard i >= edge, i < bars - edge else { return 0 }
        let x = CGFloat(i - edge + 1) / CGFloat(bars - 2 * edge + 1)
        return sin(x * .pi)
    }

    /// The bars' heights for `level` (0...1) at jitter step `step`; the gate off holds a still shape.
    static func heights(level: Float, step: Int, moving: Bool) -> [CGFloat] {
        let jitter: [CGFloat] = [1, 0.62, 0.86, 0.7, 0.95, 0.58, 0.8, 0.9, 0.66, 0.84, 0.74]
        return (0..<bars).map { i in
            let w = weight(i)
            guard w > 0 else { return barWidth }
            let amount: CGFloat = moving ? 0.18 + 0.82 * CGFloat(max(0, min(1, level))) * (jitter[checked: (i + step) % jitter.count] ?? 1) : 0.45
            return max(barWidth, (height - 2) * w * amount)
        }
    }

    /// The input level, 0...1 (each engine level update).
    func show(level: Float) {
        let moving = moves()
        if moving { phase &+= 1 }
        heights = Self.heights(level: level, step: phase, moving: moving)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, (l, h)) in zip(layers, heights).enumerated() {
            l.frame = CGRect(x: CGFloat(i) * Self.pitch, y: (Self.height - h) / 2, width: Self.barWidth, height: h)
        }
        CATransaction.commit()
        recolor()
    }

    private func recolor() {
        // Still bars (no motion) say "listening" with the accent instead of movement.
        let c = (moves() ? ink : accent).cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in layers { l.backgroundColor = c }
        CATransaction.commit()
    }
}
