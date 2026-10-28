// cmux: the message box's voice controls follow the session and the field. Not a vendored file.
import AppKit

extension ChatController {
    /// A session started or ended, or the host's engine came or went: the field's trailing slot
    /// widens or narrows, the drawn waveform gives way to the mic, and the buttons follow.
    func voiceChromeChanged(animated: Bool) {
        guard let demo else { return }
        let compose = demo.compose
        compose.hidesWaveform = voice.input != nil
        compose.trailingReserve = voice.isActive ? ComposeVoiceControls.listeningWidth : ComposeSendSlot.trailingReserve
        placeSendButton(animated: animated)
    }

    /// Places the mic (an empty field, or a session running) and "Listening…" (a session with the
    /// field still empty). Called with the send button, on every field placement and draft change.
    func placeVoiceControls() {
        guard let demo else { return }
        let compose = demo.compose
        let controls = host.voiceControls
        let active = voice.isActive
        // On every keystroke: only what changed is touched, and hidden controls are left alone.
        let empty = compose.attachmentCount == 0 && compose.text.isEmpty
        let hidden = voice.input == nil || !(active || empty)
        if controls.isHidden != hidden { controls.isHidden = hidden }
        let line = active && empty
        compose.hidesPlaceholder = line
        if host.listeningLine.isHidden == line { host.listeningLine.isHidden = !line }
        guard !hidden else { return }
        if controls.isListening != active { controls.setListening(active) }
        // A layer move; the controls view's cursor and tool tip rects follow (ComposeChromeView).
        controls.frame = ComposeVoiceControls.frame(field: compose.fieldRect, listening: active)
        controls.applyColors(ink: Fixture.waveform, accent: Fixture.caret)
        if active { controls.wave.show(level: voice.level) }
        if line { host.listeningLine.place(field: compose.fieldRect, color: Fixture.placeholder) }
    }

    /// A level-only update while listening: just the waveform.
    func voiceLevelChanged() {
        host.voiceControls.wave.show(level: voice.level)
    }
}

/// "Listening…" in the empty field while a session runs: the placeholder's place and ink, in italics.
/// A layer of the compose bar's controls view (`ComposeChromeView`): its line is
/// drawn once per ink, scale and appearance; showing or moving it changes the layer only.
@MainActor
final class ComposeListeningLine {
    weak var owner: ComposeChromeView?
    /// The drawn line, in the owner's coordinates (y down).
    let layer = CALayer()
    /// The ink, scale and appearance the line was drawn with (nil: not drawn).
    private var drawn: (color: NSColor, scale: CGFloat, appearance: NSAppearance.Name?)?
    private var scale: CGFloat = DisplayScale.current

    init() {
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "contents": NSNull(), "contentsScale": NSNull()]
        layer.contentsGravity = .topLeft
        layer.isHidden = true
    }

    /// The field's font in italics, made once (a `static let`, as the render_font rule wants).
    static let font: NSFont = NSFont(descriptor: ComposeView.font.fontDescriptor.withSymbolicTraits(.italic),
                                     size: ComposeView.font.pointSize) ?? ComposeView.font
    /// The line's size: its typographic width, the font's ascent and descent.
    static let size = CGSize(width: TextDraw.width(CmuxStrings.listening, font: ComposeListeningLine.font).rounded(.up) + 1,
                             height: (ComposeListeningLine.font.ascender - ComposeListeningLine.font.descender).rounded(.up))

    var isHidden: Bool {
        get { layer.isHidden }
        set {
            guard newValue != layer.isHidden else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.isHidden = newValue
            CATransaction.commit()
        }
    }

    /// On the field's first line, its baseline on the placeholder's.
    func place(field f: CGRect, color: NSColor) {
        let target = CGRect(origin: CGPoint(x: f.minX + 12, y: f.minY + ComposeView.firstBaseline - Self.font.ascender), size: Self.size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if layer.frame != target { layer.frame = target }
        draw(color)
        CATransaction.commit()
    }

    func rescale(_ s: CGFloat) {
        guard s != scale else { return }
        scale = s
        if let drawn { self.drawn = nil; draw(drawn.color) }
    }

    private func draw(_ color: NSColor) {
        let appearance = owner?.effectiveAppearance
        if let drawn, drawn.color == color, drawn.scale == scale, drawn.appearance == appearance?.name { return }
        drawn = (color, scale, appearance?.name)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        let font = Self.font, baseline = font.ascender
        layer.contents = UIGraphicsImageRenderer(size: Self.size, format: fmt).image { ctx in
            let paint = { TextDraw.line(CmuxStrings.listening, font: font, color: color, x: 0, baseline: baseline, in: ctx.cgContext) }
            if let appearance { appearance.performAsCurrentDrawingAppearance(paint) } else { paint() }
        }.cgImage
        layer.contentsScale = scale
    }
}
