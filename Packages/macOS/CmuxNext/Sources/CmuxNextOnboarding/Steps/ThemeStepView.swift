import AppKit
import CmuxNextDesign

/// Theme: a short list of Ghostty themes on the left, a terminal in the
/// picked theme on the right. The pick applies to the whole app at once.
final class ThemeStepView: NSView {
    private let model: ThemeStepModel
    private let list = NSStackView()
    private let preview = TerminalPreviewView()
    private var radios: [String: NSButton] = [:]
    private var shown: [String] = []
    private var loop: RenderLoop?

    init(model: ThemeStepModel) {
        self.model = model
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 9
        list.translatesAutoresizingMaskIntoConstraints = false
        addSubview(list)
        addSubview(preview)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: leadingAnchor), list.topAnchor.constraint(equalTo: topAnchor),
            list.widthAnchor.constraint(equalToConstant: 200),
            preview.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 24),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor), preview.topAnchor.constraint(equalTo: topAnchor),
            preview.heightAnchor.constraint(equalToConstant: 132),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func picked(_ sender: NSButton) {
        guard let id = radios.first(where: { $0.value === sender })?.key else { return }
        model.select(id.isEmpty ? nil : id)
    }

    private func render() {
        let choices = model.choices
        if choices.map(\.id) != shown {
            shown = choices.map(\.id)
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            radios = [:]
            for choice in choices {
                let radio = OnboardingControl.radio(OnboardingStrings.themeName(choice), target: self, action: #selector(picked(_:)))
                radios[choice.id] = radio
                list.addArrangedSubview(radio)
            }
        }
        for (id, radio) in radios { radio.state = id == (model.selected ?? "") ? .on : .off }
        preview.input = model.selectedChoice.input
    }
}
