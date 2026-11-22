import AppKit
import CmuxNextDesign

/// Number keys: one radio per choice, the keys it gives beside it.
final class TabKeysStepView: NSView {
    private let model: TabKeysStepModel
    private var radios: [TabKeysChoice: NSButton] = [:]
    private var loop: RenderLoop?

    init(model: TabKeysStepModel) {
        self.model = model
        super.init(frame: .zero)
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.translatesAutoresizingMaskIntoConstraints = false
        for choice in TabKeysChoice.allCases {
            let radio = OnboardingControl.radio(OnboardingStrings.tabKeysName(choice), target: self, action: #selector(picked(_:)))
            radios[choice] = radio
            let detail = OnboardingLabel.make(OnboardingStrings.tabKeysDetail(choice), color: Palette.textSecondary)
            let row = NSStackView(views: [radio, detail])
            row.orientation = .horizontal
            row.spacing = 12
            row.alignment = .firstBaseline
            rows.addArrangedSubview(row)
            radio.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        }
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor), rows.topAnchor.constraint(equalTo: topAnchor),
            rows.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor), rows.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func picked(_ sender: NSButton) {
        guard let choice = radios.first(where: { $0.value === sender })?.key else { return }
        model.select(choice)
    }

    private func render() {
        for (choice, radio) in radios { radio.state = choice == model.selected ? .on : .off }
    }
}
