import AppKit
import CmuxNextDesign

/// The theme choices as items (tiles, rows, swatches, radios) in a row, a
/// column or a grid. Rebuilds when the choices load, marks the selection,
/// and redraws when the app theme changes (a pick applies at once).
final class ThemeChoiceStack: NSStackView {
    private let model: ThemeStepModel
    private let columns: Int
    private let itemSpacing: CGFloat
    private let fillsWidth: Bool
    private let include: (ThemeChoice) -> Bool
    private let makeItem: () -> any ThemeChoiceItem
    private var items: [any ThemeChoiceItem] = []
    private var shown: [String]?
    private var loop: RenderLoop?

    /// `columns` > 1 makes a grid of that many items per row; 1 with a
    /// horizontal `orientation` makes one row.
    init(model: ThemeStepModel, orientation: NSUserInterfaceLayoutOrientation = .vertical, columns: Int = 1, spacing: CGFloat,
         lineSpacing: CGFloat? = nil, fillsWidth: Bool = false, include: @escaping (ThemeChoice) -> Bool = { _ in true },
         makeItem: @escaping () -> any ThemeChoiceItem) {
        self.model = model
        self.columns = columns
        itemSpacing = spacing
        self.fillsWidth = fillsWidth
        self.include = include
        self.makeItem = makeItem
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        self.orientation = columns > 1 ? .vertical : orientation
        self.spacing = columns > 1 ? (lineSpacing ?? spacing) : spacing
        alignment = self.orientation == .vertical ? .leading : .centerY
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func render() {
        _ = ThemeStore.shared.input
        let choices = model.choices.filter(include)
        if choices.map(\.id) != shown { rebuild(choices) }
        let selected = model.selectedChoice.id
        for (item, choice) in zip(items, choices) {
            item.show(choice, selected: choice.id == selected)
            item.needsDisplay = true
        }
    }

    private func rebuild(_ choices: [ThemeChoice]) {
        shown = choices.map(\.id)
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        items = choices.map { choice in
            let item = makeItem()
            item.onPress = { [weak model] in model?.select(choice.name) }
            return item
        }
        guard columns > 1 else {
            for item in items {
                addArrangedSubview(item)
                if fillsWidth { item.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
            }
            return
        }
        for start in stride(from: 0, to: items.count, by: columns) {
            let line = NSStackView(views: Array(items[start..<min(start + columns, items.count)]))
            line.spacing = itemSpacing
            line.alignment = .top
            if fillsWidth {
                line.distribution = .fillEqually
                // A short last line keeps the column width of the full ones.
                for _ in 0..<(columns - line.arrangedSubviews.count) { line.addArrangedSubview(NSView()) }
            }
            addArrangedSubview(line)
            if fillsWidth { line.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        }
    }
}
