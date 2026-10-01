import AppKit
import CmuxNextDesign

/// One screen's row: its name and a wrapping grid of variant thumbnails.
final class OnboardingGalleryRow: NSStackView {
    static let columns = 4
    private var tiles: [OnboardingGalleryTile] = []

    init(step: OnboardingModel.Step, gallery: OnboardingGalleryController, picks: any OnboardingServices,
         makeServices: @escaping @MainActor () -> any OnboardingServices) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        let variants = OnboardingVariantRegistry.variants(for: step)
        let title = OnboardingLabel.make("\(Self.name(step)) · \(variants.count) variants", font: .systemFont(ofSize: 17, weight: .semibold))
        addArrangedSubview(title)
        let grid = NSGridView()
        grid.rowSpacing = 24
        grid.columnSpacing = 20
        var row: [NSView] = []
        for variant in variants {
            let tile = OnboardingGalleryTile(variant: variant, gallery: gallery, picks: picks, services: makeServices())
            tiles.append(tile)
            row.append(tile)
            if row.count == Self.columns {
                grid.addRow(with: row)
                row = []
            }
        }
        if !row.isEmpty { grid.addRow(with: row) }
        addArrangedSubview(grid)
        setAccessibilityIdentifier("onboarding.gallery.row.\(step.rawValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refreshPicks() { for tile in tiles { tile.refreshPick() } }

    static func name(_ step: OnboardingModel.Step) -> String {
        switch step {
        case .defaultBrowser: "Default Browser"
        case .importData: "Import"
        case .theme: "Theme"
        case .accounts: "Accounts"
        }
    }
}
