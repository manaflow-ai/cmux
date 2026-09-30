import AppKit
import CmuxNextDesign

/// Step 1: theme cards (the user's Ghostty theme first) and density. Both
/// apply live, so the whole app, this window included, shows the pick.
final class WelcomeStepView: NSView {
    private let model: ThemeStepModel
    private let grid = NSGridView()
    private var cards: [String: ThemeCardView] = [:]
    private var shownChoices: [String] = []
    private let density = SegmentedPill(titles: [OnboardingStrings.compact, OnboardingStrings.comfortable])
    private var loop: RenderLoop?

    init(model: ThemeStepModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let themeHeader = OnboardingLabel.make(OnboardingStrings.theme, font: Typography.header, color: Palette.textSecondary)
        let densityHeader = OnboardingLabel.make(OnboardingStrings.density, font: Typography.header, color: Palette.textSecondary)
        let note = OnboardingLabel.make(OnboardingStrings.themeNote, font: Typography.caption, color: Palette.textTertiary, lines: 2)
        grid.rowSpacing = Metrics.space4
        grid.columnSpacing = Metrics.space4
        grid.translatesAutoresizingMaskIntoConstraints = false
        density.onSelect = { [weak model] index in model?.setDensity(index == 0 ? .compact : .comfortable) }
        let densityRow = NSStackView(views: [densityHeader, density, FlexibleSpace()])
        densityRow.spacing = Metrics.space5
        let stack = NSStackView(views: [themeHeader, grid, densityRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space5
        stack.setCustomSpacing(Metrics.space6 + Metrics.space4, after: grid)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: OnboardingMetrics.windowSize.width * 0.7),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func render() {
        let choices = model.choices
        let ids = choices.map(\.id)
        if ids != shownChoices {
            shownChoices = ids
            rebuild(choices)
        }
        for (id, card) in cards { card.isSelected = id == (model.selected ?? "") }
        density.selectedIndex = model.density == .compact ? 0 : 1
    }

    private func rebuild(_ choices: [ThemeChoice]) {
        // Removing a grid row keeps its views as subviews; remove them too.
        cards.values.forEach { $0.removeFromSuperview() }
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        cards = [:]
        let columns = 5
        var row: [NSView] = []
        for choice in choices {
            let card = ThemeCardView(choice: choice, title: choice.name ?? OnboardingStrings.ghosttyTheme)
            card.onSelect = { [weak model] in model?.select(choice.name) }
            cards[choice.id] = card
            row.append(card)
            if row.count == columns {
                grid.addRow(with: row)
                row = []
            }
        }
        if !row.isEmpty { grid.addRow(with: row) }
    }
}
