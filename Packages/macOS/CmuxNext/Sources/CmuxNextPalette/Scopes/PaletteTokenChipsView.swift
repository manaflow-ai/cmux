import AppKit
import CmuxNextDesign

/// The chosen values of a multi-value step (New Group Chat's members) as capsules before the
/// query, in the scope chips' token look. A click takes one out. When they do not all fit, the
/// newest stay and the oldest scroll off the front.
final class PaletteTokenChipsView: NSView {
    /// Takes out token `index` (a click on its chip).
    var onRemove: ((Int) -> Void)?

    private var titles: [String] = []
    private var chipViews: [PaletteScopeChipView] = []

    nonisolated override var isFlipped: Bool { true }

    func update(tokens: [PaletteToken]) {
        let titles = tokens.map(\.title)
        guard titles != self.titles else { return }
        self.titles = titles
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews = tokens.enumerated().map { index, token in
            let chip = PaletteScopeChip(levelIndex: index, scope: PaletteScopeID(rawValue: "token.\(index)"),
                                        title: token.title, symbol: token.symbol)
            let view = PaletteScopeChipView(chip: chip, style: .token, isTop: true)
            view.onClick = { [weak self] in self?.onRemove?(index) }
            view.setAccessibilityLabel(PaletteStrings.removeToken(token.title))
            view.themedToolTip = PaletteStrings.removeToken(token.title)
            view.setAccessibilityIdentifier("palette.token.\(index)")
            addSubview(view)
            return view
        }
        isHidden = chipViews.isEmpty
        needsLayout = true
    }

    /// Width every chip needs.
    var fittingWidth: CGFloat {
        guard !chipViews.isEmpty else { return 0 }
        return chipViews.map(\.fittingWidth).reduce(0, +) + CGFloat(chipViews.count - 1) * Metrics.space2
    }

    override func layout() {
        super.layout()
        // Newest last: place from the right edge leftward, hiding what does not fit.
        var right = bounds.width
        for view in chipViews.reversed() {
            let width = view.fittingWidth
            let height = view.preferredHeight
            let x = right - width
            view.isHidden = x < 0 && view !== chipViews.last
            view.frame = NSRect(x: max(0, x), y: (bounds.height - height) / 2, width: min(width, bounds.width), height: height)
            right = x - Metrics.space2
        }
    }
}
