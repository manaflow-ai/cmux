import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The "Finish setting up" card in the sidebar's bottom-left slot (``SidebarSetupCard``; Lawrence 2026-11-09,
/// msg 25425, from a reference he sent): the title and an x, a thin progress bar with "1 of N", a row per step
/// (``SidebarSetupStepRowView``) and one full-width button for the next step. It sits on the sidebar cards'
/// glass (``CardSurfaceView``). Every nested corner is concentric with the card's (a1050's rule): a row's
/// hover fill sits ``rowFillInset`` inside the card's edge, the button ``padding`` inside it.
final class SidebarSetupCardView: NSView {
    /// A row or the button ran a step: its id.
    var onRun: ((String) -> Void)?
    /// The x.
    var onClose: (() -> Void)?
    /// Its window became key while the card shows (back from a sign-in in Terminal or a browser).
    var onWindowKey: (() -> Void)?
    /// Follows the window's key state with the close button's existing key-window observation.
    private lazy var keyWatch = KeyWindowRepaint(self)
    /// The card drawn: the last one shown, kept through the exit.
    private(set) var card: SidebarSetupCard?
    /// A card is shown (the slot gives it its room).
    private(set) var isShowing = false
    let surface = CardSurfaceView()
    let titleLabel = ChromeLabel(labelWithString: "")
    let closeButton = SidebarIconButton(icon: .actionClose, pointSize: { 9 }, label: "")
    let progressLabel = ChromeLabel(labelWithString: "")
    private let track = CALayer()
    private let bar = CALayer()
    private(set) var rows: [SidebarSetupStepRowView] = []
    let button = SidebarUpdateButton()
    /// Shows and hides the card with the sidebar cards' entrance and exit (``SidebarCardTransition``).
    private(set) lazy var presence = SidebarCardPresence(self)
    /// The card plays its exit: the slot keeps it in place until it has gone.
    var isLeaving: Bool { presence.isLeaving }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        surface.takesThemeTint = true
        addSubview(surface)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        progressLabel.alignment = .right
        progressLabel.maximumNumberOfLines = 1
        // VoiceOver reads the progress as the card's value, not as loose text.
        progressLabel.setAccessibilityElement(false)
        track.masksToBounds = true
        track.addSublayer(bar)
        layer?.addSublayer(track)
        closeButton.takesKeyFocus = true
        closeButton.onPress = { [weak self] in self?.onClose?() }
        button.fixedStyle = .bordered
        button.onPress = { [weak self] in if let id = self?.card?.buttonStep { self?.onRun?(id) } }
        for view in [titleLabel, progressLabel, closeButton, button] as [NSView] { addSubview(view) }
        closeButton.setAccessibilityIdentifier("cmux.sidebar.setup.close")
        button.setAccessibilityIdentifier("cmux.sidebar.setup.next")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("cmux.sidebar.setup")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Shows `card`, or hides the view (with its exit) for nil.
    func configure(_ card: SidebarSetupCard?) {
        isShowing = card != nil
        presence.setShown(card != nil)
        guard let card, card != self.card else { return }
        let previous = self.card
        self.card = card
        titleLabel.stringValue = card.title
        progressLabel.stringValue = card.progressText
        closeButton.label = card.closeLabel
        setAccessibilityLabel(card.title)
        setAccessibilityValue(card.progressText)
        if previous?.steps.count != card.steps.count {
            rows.forEach { $0.removeFromSuperview() }
            rows = card.steps.map { _ in SidebarSetupStepRowView() }
            for row in rows { addSubview(row, positioned: .below, relativeTo: button) }
        }
        for (row, step) in zip(rows, card.steps) {
            row.configure(step)
            let id = step.id
            row.onPress = { [weak self] in self?.onRun?(id) }
        }
        button.isHidden = card.buttonTitle == nil
        if let title = card.buttonTitle {
            let busy = card.steps.first { $0.id == card.buttonStep }?.busy == true
            button.configure(title: title, enabled: !busy, help: card.steps.first { $0.id == card.buttonStep }?.help)
        }
        applyColors()
        needsLayout = true
    }

    // MARK: Metrics

    /// The card's padding: the text's inset from every edge.
    static var padding: CGFloat { Metrics.space3 }
    /// A row's hover fill inset from the card's edge (its text stays at ``padding``).
    static var rowFillInset: CGFloat { Metrics.space1 }
    static var rowHeight: CGFloat { max(22, Metrics.sidebarRowHeight - Metrics.space1) }
    static let barHeight: CGFloat = 4
    static let closeSide: CGFloat = 18

    private static var titleHeight: CGFloat { ceil(Typography.bodyEmphasized.boundingRectForFont.height) }
    private static var progressHeight: CGFloat { ceil(Typography.captionDigits.boundingRectForFont.height) }

    /// The card's height for `card`: the rows never wrap, so the width does not change it.
    static func height(for card: SidebarSetupCard) -> CGFloat {
        let button = card.buttonTitle == nil ? 0 : Metrics.space2 + SidebarUpdateButton.height
        return padding + titleHeight + Metrics.space2 + progressHeight + Metrics.space1
            + CGFloat(card.steps.count) * rowHeight + button + padding
    }

    override func layout() {
        super.layout()
        let b = bounds, pad = Self.padding
        surface.frame = b
        surface.cornerRadius = Metrics.surfaceCornerRadius
        titleLabel.font = Typography.bodyEmphasized
        progressLabel.font = Typography.captionDigits
        var y = pad
        let close = Self.closeSide
        // The x's glyph lines up with the text's trailing edge.
        closeButton.frame = NSRect(x: b.width - pad - close + (close - 9) / 2, y: y + (Self.titleHeight - close) / 2, width: close, height: close).integral
        titleLabel.frame = NSRect(x: pad, y: y, width: max(0, closeButton.frame.minX - Metrics.space2 - pad), height: Self.titleHeight)
        y += Self.titleHeight + Metrics.space2
        let countWidth = ceil(progressLabel.intrinsicContentSize.width)
        progressLabel.frame = NSRect(x: b.width - pad - countWidth, y: y, width: countWidth, height: Self.progressHeight)
        let trackWidth = max(0, progressLabel.frame.minX - Metrics.space3 - pad)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = NSRect(x: pad, y: y + (Self.progressHeight - Self.barHeight) / 2, width: trackWidth, height: Self.barHeight)
        track.cornerRadius = Self.barHeight / 2
        bar.cornerRadius = Self.barHeight / 2
        let fraction = card?.fraction ?? 0
        // A started bar always shows a sliver, so 0 of N still reads as a bar to fill.
        bar.frame = NSRect(x: 0, y: 0, width: fraction > 0 ? max(Self.barHeight, trackWidth * fraction) : 0, height: Self.barHeight)
        CATransaction.commit()
        y += Self.progressHeight + Metrics.space1
        let inset = Self.rowFillInset
        let rowRadius = Metrics.cornerRadius(insetFromSurface: inset, size: CGSize(width: b.width, height: Self.rowHeight))
        for row in rows {
            row.contentInset = pad - inset
            row.fillCornerRadius = rowRadius
            row.frame = NSRect(x: inset, y: y, width: max(0, b.width - 2 * inset), height: Self.rowHeight)
            y += Self.rowHeight
        }
        if !button.isHidden {
            y += Metrics.space2
            button.cornerRadiusOverride = Metrics.cornerRadius(insetFromSurface: pad, size: CGSize(width: b.width, height: SidebarUpdateButton.height))
            button.frame = NSRect(x: pad, y: y, width: max(0, b.width - 2 * pad), height: SidebarUpdateButton.height)
        }
        presence.didLayout()
    }

    private func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            progressLabel.textColor = Palette.textSecondary
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.backgroundColor = Palette.hoverFill.cgColor
            bar.backgroundColor = Palette.accentFill.cgColor
            CATransaction.commit()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        surface.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
        keyWatch.onBecomeKey = { [weak self] in if self?.isShowing == true { self?.onWindowKey?() } }
        keyWatch.track()
    }
}
