// cmux: the message box's voice controls (Leo's spec, 2026-10-20). Not a vendored file.
import AppKit

/// The voice controls on the field's last line, right-aligned in its trailing slot.
///
/// At rest: the mic button alone, where Messages draws its decorative waveform, shown while the
/// field is empty (text or an attachment turns the slot into the send button). While a session
/// runs the slot widens (``listeningWidth``) and shows, left to right: a live waveform of thin
/// bars that fade to dots at both ends, the return-key button that finishes and keeps the words,
/// and the mic button, highlighted in the theme's accent, which stops it too.
///
/// Layers of the compose bar's one controls view (`ComposeChromeView`): it
/// hit-tests the buttons and gives each an accessibility element; showing, moving or recolouring
/// them changes layers only.
@MainActor
final class ComposeVoiceControls {
    var onMic: () -> Void = {}
    var onFinish: () -> Void = {}
    /// The view the controls are drawn in.
    weak var owner: ComposeChromeView? {
        didSet {
            mic.owner = owner
            finish.owner = owner
            wave.owner = owner
        }
    }

    /// The controls' frame in the owner's coordinates (y down); the parts are laid out in it at once.
    let layer = CALayer()
    let mic = ComposeVoiceButton(symbol: "mic", activeSymbol: "mic.fill")
    let finish = ComposeVoiceButton(symbol: "return", activeSymbol: "return")
    let wave = ComposeVoiceWave()
    private(set) var isListening = false
    /// The mic's label now (Dictate, or Stop Dictation while a session runs).
    private(set) var micLabel = CmuxStrings.dictate

    /// The trailing width the text leaves free while a session runs.
    static let listeningWidth: CGFloat = 4 + ComposeVoiceWave.width + 6 + ComposeSendSlot.target * 2 + 2
    /// The controls' height (the send button's hit target, centred on the last line).
    static let height: CGFloat = ComposeSendSlot.target

    init() {
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "sublayers": NSNull()]
        for l in [wave.layer, finish.layer, mic.layer] { layer.addSublayer(l) }
        mic.onPress = { [weak self] in self?.onMic() }
        finish.onPress = { [weak self] in self?.onFinish() }
        mic.element.setAccessibilityIdentifier("cmux.home.composer.mic")
        finish.element.setAccessibilityIdentifier("cmux.home.composer.finishDictation")
        finish.element.setAccessibilityLabel(CmuxStrings.finishDictation)
        setListening(false)
    }

    /// The controls' frame for the field `f` (the pane's coordinates, y down): the mic's centre is the
    /// send button's (`ComposeSendSlot`), the rest extends to its left.
    static func frame(field f: CGRect, listening: Bool) -> CGRect {
        let w = listening ? listeningWidth - 4 : ComposeSendSlot.target
        let centre = CGPoint(x: f.maxX - ComposeSendSlot.centreFromRight, y: f.maxY - ComposeSendSlot.centreFromBottom)
        let right = centre.x + ComposeSendSlot.target / 2
        return CGRect(x: right - w, y: centre.y - height / 2, width: w, height: height)
    }

    /// Hidden: no layer shows and no button takes a click or is an accessibility element.
    var isHidden: Bool {
        get { layer.isHidden }
        set {
            guard newValue != layer.isHidden else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.isHidden = newValue
            CATransaction.commit()
            owner?.controlsChanged(visibility: true)
        }
    }

    /// The controls' frame in the owner's coordinates.
    var frame: CGRect {
        get { layer.frame }
        set {
            guard newValue != layer.frame else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.frame = newValue
            placeParts()
            CATransaction.commit()
            owner?.controlsChanged(visibility: false)
        }
    }

    /// The mic's and the finish button's hit targets in the owner's coordinates.
    var micFrame: CGRect { mic.layer.frame.offsetBy(dx: layer.frame.minX, dy: layer.frame.minY) }
    var finishFrame: CGRect { finish.layer.frame.offsetBy(dx: layer.frame.minX, dy: layer.frame.minY) }

    /// The mic at the right, the finish button left of it, the waveform at the left.
    private func placeParts() {
        let t = ComposeSendSlot.target, w = layer.bounds.width
        mic.layer.frame = CGRect(x: w - t, y: 0, width: t, height: t)
        finish.layer.frame = CGRect(x: w - 2 * t - 2, y: 0, width: t, height: t)
        wave.layer.frame = CGRect(x: 0, y: (t - ComposeVoiceWave.height) / 2, width: ComposeVoiceWave.width, height: ComposeVoiceWave.height)
        mic.element.frameInView = micFrame
        finish.element.frameInView = finishFrame
    }

    /// Idle (the mic alone) or a running session (waveform, finish, the highlighted mic).
    func setListening(_ listening: Bool) {
        isListening = listening
        CATransaction.begin(); CATransaction.setDisableActions(true)
        wave.layer.isHidden = !listening
        finish.layer.isHidden = !listening
        mic.isActive = listening
        placeParts()
        CATransaction.commit()
        micLabel = listening ? CmuxStrings.stopDictation : CmuxStrings.dictate
        mic.element.setAccessibilityLabel(micLabel)
        owner?.controlsChanged(visibility: true)
    }

    private var applied: (ink: NSColor, accent: NSColor, appearance: NSAppearance.Name?)?

    /// The theme's inks: the glyphs' resting colour and the accent. Unchanged inks in the same
    /// appearance touch nothing (this runs with every draft change).
    func applyColors(ink: NSColor, accent: NSColor) {
        let appearance = owner?.effectiveAppearance.name
        if let applied, applied.ink == ink, applied.accent == accent, applied.appearance == appearance { return }
        applied = (ink, accent, appearance)
        mic.applyColors(ink: ink, accent: accent)
        finish.applyColors(ink: ink, accent: ink)
        wave.setInks(ink: ink, accent: accent)
    }

    /// The owner's appearance changed: a dynamic ink resolves again for it.
    func appearanceChanged() {
        guard let applied else { return }
        self.applied = nil
        applyColors(ink: applied.ink, accent: applied.accent)
    }

    /// The window's scale: the glyphs draw again at it.
    func rescale(_ s: CGFloat) {
        if layer.contentsScale != s { layer.contentsScale = s }
        mic.rescale(s)
        finish.rescale(s)
        wave.rescale(s)
    }
}

/// One round glyph button of the voice controls (the mic, the return key). Active: the accent
/// rounded square behind an accent glyph (the mic while it records). The glyph is the symbol as a
/// mask over a fill of its ink, so a recolour is one layer property.
@MainActor
final class ComposeVoiceButton {
    var onPress: () -> Void = {}
    weak var owner: ComposeChromeView? {
        didSet { element.view = owner; applyLook() }
    }
    /// The 28 pt hit target, in the voice controls' layer.
    let layer = CALayer()
    /// The button for VoiceOver and the accessibility API.
    let element = ComposeChromeElement()
    private let glyph = CALayer()
    private let glyphMask = CALayer()
    private let backing = CALayer()
    private let symbol: String
    private let activeSymbol: String
    private var ink: NSColor = .secondaryLabelColor
    private var accent: NSColor = .controlAccentColor
    private var pressing = false
    private var scale: CGFloat = DisplayScale.current
    /// The symbol and scale the glyph's mask shows now (its image is made only when one changes).
    private var shownSymbol: (name: String, scale: CGFloat)?
    var isActive = false { didSet { if isActive != oldValue { applyLook() } } }

    init(symbol: String, activeSymbol: String) {
        self.symbol = symbol
        self.activeSymbol = activeSymbol
        let none: [String: CAAction] = ["backgroundColor": NSNull(), "opacity": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                        "contents": NSNull(), "hidden": NSNull(), "contentsScale": NSNull()]
        for l in [layer, glyph, glyphMask, backing] { l.actions = none }
        layer.bounds = CGRect(x: 0, y: 0, width: ComposeSendSlot.target, height: ComposeSendSlot.target)
        backing.cornerRadius = 7
        backing.cornerCurve = .continuous
        backing.frame = layer.bounds.insetBy(dx: 1, dy: 1)
        glyph.frame = layer.bounds
        glyph.mask = glyphMask
        layer.addSublayer(backing)
        layer.addSublayer(glyph)
        element.onPress = { [weak self] in self?.onPress(); return true }
        applyLook()
    }

    func applyColors(ink: NSColor, accent: NSColor) {
        self.ink = ink
        self.accent = accent
        applyLook()
    }

    /// A press is held on the button with the pointer over it.
    func setPressing(_ on: Bool) {
        guard on != pressing else { return }
        pressing = on
        applyLook()
    }

    func rescale(_ s: CGFloat) {
        guard s != scale else { return }
        scale = s
        applyLook()
    }

    private func applyLook() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let name = isActive ? activeSymbol : symbol
        if shownSymbol.map({ $0.name != name || $0.scale != scale }) ?? true {
            shownSymbol = (name, scale)
            placeGlyph(NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(FieldChrome.glyphConfig))
        }
        let glyphInk = isActive ? accent : ink, backingInk = accent.withAlphaComponent(0.22)
        glyph.backgroundColor = owner?.cgColor(glyphInk) ?? glyphInk.cgColor
        backing.backgroundColor = owner?.cgColor(backingInk) ?? backingInk.cgColor
        backing.opacity = isActive ? 1 : 0
        layer.opacity = pressing ? 0.6 : 1
        CATransaction.commit()
    }

    /// The symbol's shape as the glyph's mask: drawn at its own size, centred in the button (as an
    /// image view that does not scale it), at the window's scale.
    private func placeGlyph(_ image: NSImage?) {
        for l in [layer, glyph, glyphMask, backing] { l.contentsScale = scale }
        glyphMask.frame = glyph.bounds
        guard let image else { glyphMask.contents = nil; return }
        let b = glyph.bounds, size = image.size
        let box = CGRect(x: ((b.width - size.width) / 2).rounded(), y: ((b.height - size.height) / 2).rounded(),
                         width: size.width, height: size.height)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        // The renderer's context is y-down and current as a flipped NSGraphicsContext (ContextScope).
        glyphMask.contents = UIGraphicsImageRenderer(size: b.size, format: fmt).image { _ in
            image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }.cgImage
    }
}

/// The live waveform: thin vertical bars whose height follows the input level, falling to dots at
/// both ends. Each level moves the bars in one frame (no animation object); with the gate off
/// (Reduce Motion, animations off) the bars stand still, tinted the accent while listening.
@MainActor
final class ComposeVoiceWave {
    static let bars = 19
    static let pitch: CGFloat = 4
    static let barWidth: CGFloat = 1.6
    static let width: CGFloat = CGFloat(bars - 1) * pitch + barWidth
    static let height: CGFloat = 20
    weak var owner: ComposeChromeView? { didSet { recolor() } }
    /// Whether the bars move with the level (the host's motion gate; MessagesLabHomeView.voiceMotionGate).
    var moves: () -> Bool = { MessagesLabHomeView.voiceMotionGate() }
    /// The bars' container, in the voice controls' layer.
    let layer = CALayer()
    private var ink: NSColor = .secondaryLabelColor
    private var accent: NSColor = .controlAccentColor
    private var layers: [CALayer] = []
    /// A step through the bars' jitter so a steady level still looks alive.
    private var phase = 0
    private(set) var heights: [CGFloat] = []

    init() {
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        for _ in 0..<Self.bars {
            let l = CALayer()
            l.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "backgroundColor": NSNull(), "contentsScale": NSNull()]
            l.cornerRadius = Self.barWidth / 2
            layer.addSublayer(l)
            layers.append(l)
        }
        show(level: 0)
    }

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

    /// The theme's inks (only when one or the appearance changed: `ComposeVoiceControls.applyColors`).
    func setInks(ink: NSColor, accent: NSColor) {
        self.ink = ink
        self.accent = accent
        recolor()
    }

    func rescale(_ s: CGFloat) {
        for l in [layer] + layers where l.contentsScale != s { l.contentsScale = s }
    }

    private func recolor() {
        // Still bars (no motion) say "listening" with the accent instead of movement.
        let ink = moves() ? ink : accent
        let c = owner?.cgColor(ink) ?? ink.cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in layers { l.backgroundColor = c }
        CATransaction.commit()
    }
}
