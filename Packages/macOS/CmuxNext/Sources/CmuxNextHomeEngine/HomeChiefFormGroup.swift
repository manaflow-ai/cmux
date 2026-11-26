import AppKit
import CmuxNextDesign

/// One group of the Chief profile's rows, drawn as macOS 26 draws an info panel's (Messages' and
/// Contacts' info, System Settings' forms; Lawrence 2026-11-23, "drastically improve these UIs"): the rows
/// on one rounded fill (edged by a hairline where text contrast keeps the fill faint, ``Palette/groupStroke``),
/// a hairline between two shown rows. The rows keep the card's two columns
/// (``HomeChiefSettingsView/row(_:_:fills:)``); a hidden row takes its hairline with it.
@MainActor
final class HomeChiefFormGroup: NSStackView {
    static let corner: CGFloat = 10
    /// The rows' inset from the fill's sides.
    static let padding: CGFloat = 10
    /// The space between two rows; the hairline runs through its middle.
    static let rowGap: CGFloat = 12
    private var hairlines: [CALayer] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Self.rowGap
        edgeInsets = NSEdgeInsets(top: 8, left: Self.padding, bottom: 8, right: Self.padding)
        wantsLayer = true
        layer?.cornerRadius = Self.corner
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Adds `row` across the group, inside its padding.
    func add(_ row: NSView) {
        row.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: widthAnchor, constant: -2 * Self.padding).isActive = true
    }

    override func layout() {
        super.layout()
        placeHairlines()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    /// A hairline in the middle of each gap between two shown rows, inset as the rows are.
    private func placeHairlines() {
        let shown = arrangedSubviews.filter { !$0.isHidden }
        let gaps = zip(shown, shown.dropFirst()).map { above, below in
            above.frame.midY < below.frame.midY ? (above.frame.maxY + below.frame.minY) / 2 : (above.frame.minY + below.frame.maxY) / 2
        }
        while hairlines.count < gaps.count {
            let line = CALayer()
            layer?.addSublayer(line)
            hairlines.append(line)
        }
        let thickness = 1 / (window?.backingScaleFactor ?? 2)
        let color = performWithTheme { Palette.separator.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, line) in hairlines.enumerated() {
            line.isHidden = index >= gaps.count
            guard index < gaps.count else { continue }
            line.backgroundColor = color
            line.frame = CGRect(x: Self.padding, y: (gaps[index] - thickness / 2).rounded(.down), width: bounds.width - 2 * Self.padding, height: thickness)
        }
        CATransaction.commit()
    }

    private func applyTheme() {
        performWithTheme {
            layer?.backgroundColor = Palette.groupFill.cgColor
            layer?.borderColor = Palette.groupStroke.cgColor
        }
        layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
        needsLayout = true
    }
}
