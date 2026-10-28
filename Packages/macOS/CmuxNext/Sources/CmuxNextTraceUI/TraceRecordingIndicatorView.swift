public import AppKit
public import CmuxNextDesign
public import CmuxNextWakeups

/// A window's "Recording trace" indicator in the top row, with Stop (p09-observability task 133): shown while
/// ``TraceRecordingState`` says a recording runs, hidden otherwise. A still red dot, the words in secondary text
/// and Stop on the hover gray (no accent color). It fades in through the `indicators` motion gate and has no
/// loop: the indicator never adds frames to the trace it shows. While the recording's parts stop, Stop reads
/// Stopping… and is disabled.
///
/// The owner (the window's root) places it in the top row: ``width`` is its size, and `onVisibilityChange` is
/// called when it shows, hides or changes width, never during a layout. It follows the state through the
/// window's node: a hidden window catches up when it shows.
public final class TraceRecordingIndicatorView: NSView, TitlebarPressDeciding {
    public static let identifier = "cmux.titlebar.traceRecording"
    /// The dot's side, in points.
    private static let dotSide: CGFloat = 6

    private let dot = NSView()
    private let label = ThemedLabel(labelWithString: TraceRecordingStrings.title)
    /// Stop (tests press it).
    let stopButton = NSButton()
    private let state: TraceRecordingState
    private let onVisibilityChange: () -> Void
    private var phaseWatch: VisibleObservation<TraceRecordingState.Phase>?
    /// The phase shown now (tests read it).
    private(set) var shownPhase = TraceRecordingState.Phase.idle

    /// - Parameters:
    ///   - state: The app's one recording state.
    ///   - node: The window's node in the visibility tree.
    ///   - mainWork: The app's main-thread scheduler.
    ///   - onVisibilityChange: Called when the indicator shows, hides or changes width: the owner places it again.
    public init(state: TraceRecordingState, node: VisibilityNode, mainWork: MainWorkScheduler,
                onVisibilityChange: @escaping () -> Void) {
        self.state = state
        self.onVisibilityChange = onVisibilityChange
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        dot.wantsLayer = true
        addSubview(dot)
        label.font = Typography.caption
        label.ink = .secondary
        addSubview(label)
        stopButton.isBordered = false
        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        stopButton.setAccessibilityIdentifier("\(Self.identifier).stop")
        stopButton.setAccessibilityLabel(TraceRecordingStrings.stopHelp)
        stopButton.themedToolTip = TraceRecordingStrings.stopHelp
        addSubview(stopButton)
        setAccessibilityIdentifier(Self.identifier)
        applyColors()
        phaseWatch = VisibleObservation(node, owner: "TraceRecordingIndicator.phase", on: mainWork, firstFrame: true) {
            state.phase
        } apply: { [weak self] phase in
            self?.show(phase)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress { .staysPut }

    /// The dot, the words and Stop, with `space2` at each end and between the words and Stop.
    public var width: CGFloat {
        Metrics.space2 + Self.dotSide + Metrics.space1 + ceil(label.intrinsicContentSize.width) + Metrics.space2
            + ceil(stopButton.intrinsicContentSize.width) + Metrics.space2
    }

    override public func layout() {
        super.layout()
        layer?.cornerRadius = Metrics.chipCornerRadius(height: bounds.height)
        let side = Self.dotSide
        dot.frame = CGRect(x: Metrics.space2, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
        dot.layer?.cornerRadius = side / 2
        let text = label.intrinsicContentSize
        label.frame = CGRect(x: dot.frame.maxX + Metrics.space1, y: ((bounds.height - text.height) / 2).rounded(),
                             width: ceil(text.width), height: text.height)
        let button = stopButton.intrinsicContentSize
        stopButton.frame = CGRect(x: label.frame.maxX + Metrics.space2, y: ((bounds.height - button.height) / 2).rounded(),
                                  width: ceil(button.width), height: button.height)
    }

    // visibility-walk-allow: three color stores and one title, no layout or text measure; cheaper than a deferral
    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func show(_ phase: TraceRecordingState.Phase) {
        let (wasHidden, oldWidth) = (isHidden, width)
        shownPhase = phase
        isHidden = phase == .idle
        stopButton.isEnabled = phase == .recording
        applyColors()
        if wasHidden, !isHidden, let layer {
            Motion.indicators.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
        }
        if wasHidden != isHidden || oldWidth != width { onVisibilityChange() }
    }

    /// Theme tokens only: the danger dot, Stop in primary text, the hover gray behind it all.
    private func applyColors() {
        performWithTheme {
            dot.layer?.backgroundColor = Palette.danger.cgColor
            layer?.backgroundColor = Palette.hoverFill.cgColor
            let title = shownPhase == .stopping ? TraceRecordingStrings.stopping : TraceRecordingStrings.stop
            stopButton.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: Typography.caption,
                .foregroundColor: shownPhase == .stopping ? Palette.textSecondary : Palette.textPrimary,
            ])
        }
    }

    @objc private func stopPressed() {
        state.requestStop()
    }
}
