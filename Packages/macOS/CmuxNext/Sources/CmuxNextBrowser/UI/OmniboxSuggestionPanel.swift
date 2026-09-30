import AppKit
import CmuxNextDesign
import QuartzCore

/// The lower part of the suggestion card (Helium's omnibox popup): a
/// non-activating child panel flush under the bar, as wide as the card top
/// (`OmnibarCardTopView`), rounded at the bottom only, with 28 pt rows whose
/// icon and text line up with the bar's chip and text. A separate window, so
/// it stays above child-window engines (CEF) and never takes key status from
/// the field being edited.
final class OmniboxSuggestionPanel {
    var onPick: ((Int) -> Void)?

    private var panel: SuggestionWindow?
    private let content = SuggestionCardView()
    private var rows: [SuggestionRowView] = []

    /// Shadow room around the card inside the panel (none at the top: the
    /// card continues the bar there).
    private static let shadowMargin: CGFloat = 16

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ suggestions: [BrowserSuggestion], selected: Int?, below anchor: NSView, in window: NSWindow) {
        let panel = panel ?? makePanel()
        rows.forEach { $0.removeFromSuperview() }
        rows = suggestions.enumerated().map { index, suggestion in
            let row = SuggestionRowView(suggestion: suggestion)
            row.onClick = { [weak self] in self?.onPick?(index) }
            row.isSelected = index == selected
            return row
        }
        rows.forEach { content.card.addSubview($0) }

        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let outset = OmnibarStyle.cardSideOutset
        let rowStep = OmnibarStyle.rowHeight + OmnibarStyle.rowGap
        let cardHeight = CGFloat(rows.count) * rowStep + OmnibarStyle.cardBottomPadding
        let cardWidth = anchorRect.width + 2 * outset
        let margin = Self.shadowMargin
        let frame = NSRect(
            x: anchorRect.minX - outset - margin,
            y: anchorRect.minY - cardHeight - margin,
            width: cardWidth + 2 * margin,
            height: cardHeight + margin
        )
        content.cardFrame = NSRect(x: margin, y: margin, width: cardWidth, height: cardHeight)
        // Rows from the top, inset like Helium (4 at the sides, 2 above each).
        for (index, row) in rows.enumerated() {
            let top = cardHeight - OmnibarStyle.rowGap - CGFloat(index) * rowStep
            row.frame = NSRect(
                x: OmnibarStyle.rowSideInset,
                y: top - OmnibarStyle.rowHeight,
                width: cardWidth - 2 * OmnibarStyle.rowSideInset,
                height: OmnibarStyle.rowHeight
            )
            // Icon and text line up with the bar's chip and text.
            row.leadingIconCenter = outset + OmnibarStyle.chipLeading + OmnibarStyle.chipSize / 2 - OmnibarStyle.rowSideInset
            row.textLeading = outset + OmnibarStyle.chipLeading + OmnibarStyle.chipSize + OmnibarStyle.textLeading - OmnibarStyle.rowSideInset
        }

        panel.appearance = window.effectiveAppearance
        panel.setFrame(frame, display: true)
        content.needsLayout = true
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible {
            // No fade: the card top in the bar appears at the same moment.
            panel.alphaValue = 1
            panel.orderFront(nil)
        }
    }

    func select(_ index: Int?) {
        for (offset, row) in rows.enumerated() {
            row.isSelected = offset == index
        }
    }

    func dismiss() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> SuggestionWindow {
        let window = SuggestionWindow(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        ThemeStore.shared.adopt(window)
        window.isOpaque = false
        window.backgroundColor = .clear
        // The card draws its own shadow so none falls on the seam with the bar.
        window.hasShadow = false
        window.level = .popUpMenu
        window.hidesOnDeactivate = true
        window.isReleasedWhenClosed = false
        window.contentView = content
        panel = window
        return window
    }
}

final class SuggestionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Transparent panel content holding the card layer and its shadow.
final class SuggestionCardView: NSView {
    let card = NSView()
    var cardFrame: NSRect = .zero { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        card.wantsLayer = true
        card.layer?.cornerRadius = OmnibarStyle.cardCornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.layer?.masksToBounds = false
        card.layer?.shadowOpacity = 0.16
        card.layer?.shadowRadius = 8
        card.layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        card.frame = cardFrame
        // The shadow shape reaches above the panel top, so the seam with the
        // bar's card top shows no shadow edge.
        let shape = CGRect(x: 0, y: 0, width: cardFrame.width, height: cardFrame.height + 40)
        card.layer?.shadowPath = CGPath(roundedRect: shape, cornerWidth: OmnibarStyle.cardCornerRadius, cornerHeight: OmnibarStyle.cardCornerRadius, transform: nil)
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = OmnibarStyle.cardFill.cgColor
        }
    }
}
