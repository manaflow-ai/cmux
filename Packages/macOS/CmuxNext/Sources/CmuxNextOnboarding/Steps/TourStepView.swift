import AppKit
import CmuxNextDesign

/// Step 5: a short list of ideas on the left; the selected one on the right
/// with its live shortcuts as key caps. No page is required reading.
final class TourStepView: NSView {
    private let model: TourStepModel
    private var rows: [SelectableCard] = []
    private let detail = ThemedView()
    private let hero = NSImageView()
    private let heading = OnboardingLabel.make(font: Typography.title)
    private let body = OnboardingLabel.make(font: Typography.subtitle, color: Palette.textSecondary, lines: 4)
    private let keys = NSStackView()
    private let illustration = TourIllustrationView()
    private var shownPage: Int?
    private var loop: RenderLoop?

    init(model: TourStepModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = Metrics.space2
        list.alignment = .leading
        list.translatesAutoresizingMaskIntoConstraints = false
        for (index, page) in TourStepModel.pages.enumerated() {
            let row = tourRow(page)
            row.onSelect = { [weak model] in model?.show(index) }
            rows.append(row)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        detail.fill = { Palette.hoverFill }
        detail.border = { Palette.separator }
        detail.cornerRadius = OnboardingMetrics.cornerRadius
        hero.symbolConfiguration = .init(pointSize: Metrics.space6 * 2, weight: .light)
        hero.contentTintColor = Palette.textPrimary
        keys.spacing = Metrics.space4
        let content = NSStackView(views: [hero, heading, body, keys])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Metrics.space4
        content.setCustomSpacing(Metrics.space6, after: hero)
        content.setCustomSpacing(Metrics.space6, after: body)
        content.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(content)
        detail.addSubview(illustration)
        addSubview(list)
        addSubview(detail)
        let inset = Metrics.space6 + Metrics.space4
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: leadingAnchor), list.topAnchor.constraint(equalTo: topAnchor),
            list.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.36),
            detail.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: Metrics.space6),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: topAnchor), detail.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: detail.topAnchor, constant: inset),
            illustration.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: inset),
            illustration.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -inset),
            illustration.topAnchor.constraint(greaterThanOrEqualTo: content.bottomAnchor, constant: Metrics.space6),
            illustration.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -inset),
        ])
        let height = illustration.heightAnchor.constraint(equalTo: detail.heightAnchor, multiplier: 0.4)
        height.priority = .defaultHigh
        height.isActive = true
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func tourRow(_ page: TourPage) -> SelectableCard {
        let row = SelectableCard()
        row.selection = .fill
        let icon = NSImageView(image: NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Palette.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = OnboardingLabel.make(OnboardingStrings.tourTitle(page.kind), font: Typography.body)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = Metrics.space4
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Metrics.space5),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -Metrics.space4),
            stack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: OnboardingMetrics.rowHeight),
            icon.widthAnchor.constraint(equalToConstant: Metrics.space6 + Metrics.space2),
        ])
        row.setAccessibilityLabel(label.stringValue)
        return row
    }

    private func render() {
        let index = model.page
        for (i, row) in rows.enumerated() { row.isSelected = i == index }
        guard index != shownPage else { return }
        let forward = (shownPage ?? -1) < index
        shownPage = index
        let page = TourStepModel.pages[index]
        hero.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil)
        heading.stringValue = OnboardingStrings.tourTitle(page.kind)
        body.stringValue = OnboardingStrings.tourBody(page.kind)
        illustration.kind = page.kind
        keys.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for shortcut in model.shortcuts(for: page) { keys.addArrangedSubview(KeycapView.caps(for: shortcut)) }
        StepTransition.reveal(detail, forward: forward, distance: OnboardingMetrics.slideDistance / 2)
    }
}
