import AppKit

/// The Toast Playground's Corner row: the close toast Leo saw, at each corner the design scale offers, light and
/// dark (Leo, 2026-11-22: "also the toast is this awkward pill glass. im not sure if it should be that rounded.
/// what's our design language?"). The rest of the app rounds by one rectangle scale, not capsules: 8 for
/// popups, 12 for cards and the composer (`webviews/src/pages/shared/desktop.css`, design/grid.md), and
/// `SurfaceRole.toast` says "a rounded rect, never a capsule, even on one line". The proposal is the 12 pt one.
@MainActor
final class CmuxToastPlaygroundCorners: NSView {
    /// One variant: a style, the corner it draws with, its name.
    struct Variant {
        let id: String
        let title: String
        let style: CmuxToastStyle
        let corner: CmuxToastLook.Corner?
    }

    static let variants: [Variant] = [
        Variant(id: "capsule", title: "Liquid Glass capsule: half the height (Leo’s screenshot)", style: .capsule, corner: nil),
        Variant(id: "concentric", title: "Standard today: button corner + padding, 16 pt on 38 pt", style: .standard, corner: .concentric),
        Variant(id: "points12", title: "12 pt, the card and composer corner (proposed)", style: .standard, corner: .points(12)),
        Variant(id: "points8", title: "8 pt, the popup corner", style: .standard, corner: .points(8)),
        Variant(id: "surfaceRole", title: "The toast surface role’s corner", style: .standard, corner: .surfaceRole),
        Variant(id: "solid12", title: "12 pt, solid (no glass)", style: .solid, corner: .points(12)),
    ]

    /// The one-line Undo Leo saw, and a two-line prompt.
    static let samples: [CmuxToast] = [
        CmuxToast(id: "playground.corner.undo", message: "Closed “Background tasks”", action: .undo()),
        CmuxToastPlaygroundSamples.kinds[5],
    ]

    private(set) var sheets: [CmuxToastPlaygroundSheet] = []

    init(themes: CmuxToastPlaygroundThemes, tuning: CmuxToastTuning) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(themes: themes, tuning: tuning)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build(themes: CmuxToastPlaygroundThemes, tuning: CmuxToastTuning) {
        let title = ThemedLabel(labelWithString: "Corner")
        title.font = Typography.system(size: TypeScale.title, weight: TypeScale.emphasis)
        title.themeColor = { Palette.textPrimary }
        let summary = ThemedLabel(wrappingLabelWithString:
            "How round a toast is, on the app's rectangle scale: popups 8, cards and the composer 12. Proposed: 12 pt.")
        summary.font = Typography.body
        summary.themeColor = { Palette.textSecondary }
        var views: [NSView] = [title, summary]
        var pairs: [NSStackView] = []
        for variant in Self.variants {
            let label = ThemedLabel(labelWithString: variant.title)
            label.font = Typography.system(size: TypeScale.body, weight: TypeScale.emphasis)
            label.themeColor = { Palette.textPrimary }
            let pair = NSStackView(views: [false, true].map { isDark in
                let sheet = CmuxToastPlaygroundSheet(style: variant.style, isDark: isDark, themes: themes, tuning: tuning,
                                                     corner: variant.corner, samples: Self.samples, name: "corner.\(variant.id)")
                sheets.append(sheet)
                return sheet
            })
            pair.orientation = .horizontal
            pair.distribution = .fillEqually
            pair.alignment = .top
            pair.spacing = 12
            pair.setAccessibilityIdentifier("cmux.toastPlayground.corner.\(variant.id)")
            views += [label, pair]
            pairs.append(pair)
        }
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.setCustomSpacing(2, after: title)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            summary.widthAnchor.constraint(equalTo: column.widthAnchor),
        ] + pairs.map { $0.widthAnchor.constraint(equalTo: column.widthAnchor) })
    }
}
