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
        let frame = ComposeVoiceControls.frame(field: compose.fieldRect, listening: active)
        if controls.frame != frame {
            controls.frame = frame
            controls.window?.invalidateCursorRects(for: controls)
        }
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
final class ComposeListeningLine: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.stringValue = CmuxStrings.listening
        label.font = Self.font
        label.lineBreakMode = .byClipping
        label.setAccessibilityElement(false)
        addSubview(label)
        isHidden = true
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The field's font in italics, made once (a `static let`, as the render_font rule wants).
    static let font: NSFont = NSFont(descriptor: ComposeView.font.fontDescriptor.withSymbolicTraits(.italic),
                                     size: ComposeView.font.pointSize) ?? ComposeView.font

    /// On the field's first line, its baseline on the placeholder's.
    func place(field f: CGRect, color: NSColor) {
        label.textColor = color
        label.sizeToFit()
        let size = label.frame.size
        let origin = CGPoint(x: f.minX + 12 - 2, y: f.minY + ComposeView.firstBaseline - label.firstBaselineOffsetFromTop)
        let target = CGRect(origin: origin, size: CGSize(width: size.width, height: size.height))
        if frame != target { frame = target }
        label.frame = bounds
    }
}
