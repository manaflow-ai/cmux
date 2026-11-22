import AppKit
import CmuxNextCompat
import CmuxNextDesign
import Observation

/// Look B's screen area while there is no picture: a calm blank on the pane's ground with one small mark (the shared
/// loading mark, revealed after ~300 ms, or the state's glyph), the state's reason under it when it has one, and the
/// shared Sign In button when this Mac is signed out. The words and buttons are in the strip; nothing here is a card.
/// The pane hides it while an outage keeps the last frame up, so it never covers the picture.
@MainActor
final class MacScreenStatusStripBody: MacScreenThemedView {
    /// The loading mark's side: small, a calm mark rather than a card's spinner.
    static let spinnerSide: CGFloat = 16
    /// The reason's line width, at most.
    static let captionWidth: CGFloat = 360

    private let model: MacScreenPaneModel
    /// Follows the model (``ObservationStream``); ends once the view is gone.
    private var watch: Task<Void, Never>?
    private let actions: MacScreenChromeActions
    private let stack = MacScreenStack.make(.vertical, spacing: Metrics.space5, alignment: .centerX)
    private let spinner = StatusIndicatorView.spinner()
    private var shown: MacScreenStripState?

    init(model: MacScreenPaneModel, actions: MacScreenChromeActions) {
        self.model = model
        self.actions = actions
        super.init(frame: .zero)
        wantsLayer = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.wantsLayer = true
        spinner.alphaValue = 0.6
        addSubview(stack)
        // Below required: a hidden body can be zero-sized.
        let inset = stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -Metrics.space6 * 2)
        inset.priority = .defaultHigh
        NSLayoutConstraint.activate([
            inset,
            spinner.widthAnchor.constraint(equalToConstant: Self.spinnerSide),
            spinner.heightAnchor.constraint(equalToConstant: Self.spinnerSide),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: Self.captionWidth),
        ])
        track()
    }

    override var isFlipped: Bool { true }

    override var isHidden: Bool {
        didSet { if isHidden != oldValue { updateSpin() } }
    }

    /// Only the Sign In button takes clicks; the blank around it is the screen area's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        var view = hit
        while let candidate = view, candidate !== self {
            if candidate is NSButton { return hit }
            view = candidate.superview
        }
        return nil
    }

    private func track() {
        // At once for the first frame (the gallery draws in this turn), then on each change.
        apply()
        watch = Task { [weak self] in
            for await _ in ObservationStream({ [weak self] in self?.apply() }) { if self == nil { return } }
        }
    }

    private func apply() {
        let state = model.card.map { MacScreenStripState.make($0, model: model) }
        guard state != shown else { return }
        let wasLoading = shown?.mark == .loading
        shown = state
        rebuild(state, revealsLate: !wasLoading)
    }

    private func rebuild(_ state: MacScreenStripState?, revealsLate: Bool) {
        for view in stack.arrangedSubviews { // visible-only: the body holds at most a mark, two lines and two buttons
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard let state else {
            updateSpin()
            return
        }
        switch state.mark {
        case .loading:
            stack.addArrangedSubview(spinner)
            if revealsLate { reveal(spinner) }
        case let .glyph(symbol, ink):
            let font = MacScreenType.glyph
            let glyph = MacScreenGlyph(symbol, font: font, ink: ink)
            glyph.heightAnchor.constraint(equalToConstant: ceil(font.ascender - font.descender)).isActive = true
            stack.addArrangedSubview(glyph)
        }
        if let caption = state.caption, !caption.isEmpty {
            let text = MacScreenText(caption, font: MacScreenType.body, ink: \.secondary, wraps: true, alignment: .center, width: Self.captionWidth)
            stack.addArrangedSubview(text)
        }
        if state.signIn {
            let button = SignInButton { [weak self] in self?.actions.signIn() }
            button.setAccessibilityIdentifier("macScreen.card.signIn")
            stack.addArrangedSubview(button)
        }
        paint(stack)
        updateSpin()
        needsLayout = true
    }

    /// The loading mark shows only after ~300 ms (a blink of a state shows nothing), on the layer's clock.
    private func reveal(_ view: NSView) {
        guard let layer = view.layer else { return }
        let fade = Motion.overlays.scheduledFade(.fadeIn, "opacity", from: Float(0), to: Float(view.alphaValue),
                                                 after: MacScreenStatusStrip.revealDelay, on: layer)
        fade.fillMode = .both
        layer.add(fade, forKey: "cmux.stripReveal")
    }

    private func updateSpin() {
        spinner.spin(!isHidden && shown?.mark == .loading)
    }
}
