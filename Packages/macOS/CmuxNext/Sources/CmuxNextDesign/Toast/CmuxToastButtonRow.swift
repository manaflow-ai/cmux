public import AppKit
public import CmuxNextDesignTokens

/// How a toast sets its buttons apart from its message (Debug Settings > Toasts, "Buttons"). Leo
/// 2026-11-21 on the "Option or Shift + drag selects text  Don't Show Again  ×" hint: "this styling is
/// completely off": a quiet text button right after the message read as more of the sentence.
public nonisolated enum CmuxToastButtonRow: String, Sendable, CaseIterable, TunableChoice {
    /// The buttons follow the message as text, a gap apart (the look before 2026-11-21).
    case plain
    /// A short vertical hairline between the message and the buttons.
    case divider
    /// Don't Show Again and the other quiet buttons rest on a faint fill, so they read as buttons.
    case chips

    public var tunableTitle: String {
        switch self {
        case .plain: "Plain: buttons follow the message"
        case .divider: "Divider between message and buttons"
        case .chips: "Quiet buttons on a faint fill"
        }
    }
}

/// The hairline between a toast's message and its buttons (``CmuxToastButtonRow/divider``): the toast's
/// tertiary text color, fitted to its ground, at a third, so it shows on glass and on the opaque surface.
@MainActor
final class CmuxToastDivider: NSView {
    private let reduceTransparency: ReduceTransparency

    init(reduceTransparency: ReduceTransparency) {
        self.reduceTransparency = reduceTransparency
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 1),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// As tall as a line of the message, shorter than the buttons beside it.
    static let height: CGFloat = 14

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let ground = reduceTransparency
        layer?.backgroundColor = performWithTheme { Palette.toastText(.tertiary, reduceTransparency: ground).withAlphaComponent(0.35).cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension CmuxToastView {
    /// The hairline between the message and the buttons (``CmuxToastButtonRow/divider``).
    public var divider: NSView? { Self.firstDivider(in: self) }

    private static func firstDivider(in view: NSView) -> NSView? {
        for sub in view.subviews { if let found = sub as? CmuxToastDivider ?? firstDivider(in: sub) { return found } }
        return nil
    }

    /// Sets the buttons apart from the message, as Debug Settings > Toasts > Buttons picks
    /// (``CmuxToastTuning/buttonRow``): a hairline after the message, or a faint resting fill on the quiet
    /// buttons. A toast with only close keeps it a gap after the message.
    func separateButtons(in row: NSStackView, after text: NSView) {
        guard secondaryButton != nil || actionButton != nil || neverShowButton != nil else { return }
        switch tuning.buttonRow {
        case .plain:
            break
        case .divider:
            guard let index = row.arrangedSubviews.firstIndex(of: text) else { return }
            let line = CmuxToastDivider(reduceTransparency: reduceTransparency)
            row.insertArrangedSubview(line, at: index + 1)
            // The same room on both sides of the line, to the message's last glyph and to the first title
            // (a text button's title sits its padding in from its frame).
            let gap = Metrics.space4
            row.setCustomSpacing(gap, after: text)
            row.setCustomSpacing(max(0, gap - CmuxToastButton.titlePadding), after: line)
        case .chips:
            for button in [secondaryButton, neverShowButton].compactMap({ $0 }) { button.restsOnFill = true }
        }
    }
}
