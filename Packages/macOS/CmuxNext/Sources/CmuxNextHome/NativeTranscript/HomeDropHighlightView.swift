import AppKit
import CmuxNextDesign

/// Home's drop target state (one per transcript view, ``HomeNativeTranscriptView/drop``): the
/// highlight, the current drag's answer (read once per drag), what a drag's pasteboard holds as the
/// intake reads it, and the drops whose promised files are still on their way.
final class HomeDropState {
    let highlight = HomeDropHighlightView(frame: .zero)
    /// Whether the current drag (its sequence number) is one the composer takes.
    var answer: (sequence: Int, accepts: Bool)?
    /// The pasteboard itself; a value in tests (a ci-step mini has no pasteboard server).
    var contents: (NSPasteboard) -> any HomePasteboardContents = { $0 }
    /// Drops whose promised files are still on their way (the notice says so meanwhile).
    var pending = 0

    /// Puts the highlight over `view` (it takes its inset frame each time it shows).
    func install(in view: NSView) {
        highlight.frame = view.bounds
        highlight.autoresizingMask = [.width, .height]
        view.addSubview(highlight)
    }
}

/// Home's drop highlight: while a drag that the composer takes is over the
/// pane (the transcript, the header, the field, or the conversation list
/// beside it), the whole pane shows the theme's focus ring as a rounded
/// outline over a faint tint of it, the border-only look of the panes' own
/// drop outline. Drawn only; it never takes a click or a drag.
final class HomeDropHighlightView: NSView {
    static let inset: CGFloat = 6
    static let cornerRadius: CGFloat = 12
    static let lineWidth: CGFloat = 2
    static let fillAlpha: CGFloat = 0.06

    private(set) var isShowing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.borderWidth = Self.lineWidth
        isHidden = true
        alphaValue = 0
        setAccessibilityElement(false)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        performWithTheme {
            layer?.borderColor = Palette.focusRing.cgColor
            layer?.backgroundColor = Palette.focusRing.withAlphaComponent(Self.fillAlpha).cgColor
        }
    }

    /// Fades in or out (Motion.home: no animation at all when motion is off; the end state is set
    /// in this frame either way).
    func show(_ shown: Bool) {
        guard shown != isShowing else { return }
        isShowing = shown
        if shown {
            // The pane's size now, inset (a frame set at install, from zero bounds, would be null).
            if let pane = superview?.bounds, pane.width > 2 * Self.inset, pane.height > 2 * Self.inset {
                frame = pane.insetBy(dx: Self.inset, dy: Self.inset)
            }
            applyTheme()
            isHidden = false
        }
        Motion.home.animate(shown ? .fadeIn : .fadeOut, in: self, { self.animator().alphaValue = shown ? 1 : 0 }, completion: { [weak self] in
            guard let self, !self.isShowing else { return }
            self.isHidden = true
        })
    }
}
