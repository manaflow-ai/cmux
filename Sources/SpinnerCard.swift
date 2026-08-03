#if DEBUG
import AppKit

@MainActor
final class SpinnerCard: NSView {
    init(spec: SpinnerSpec) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.03).cgColor

        let well = NSView()
        well.wantsLayer = true
        well.layer?.cornerRadius = 8
        well.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        let spinner = spec.makeView()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(spinner)

        let title = NSTextField(labelWithString: spec.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let mechanism = NSTextField(wrappingLabelWithString: spec.mechanism)
        mechanism.font = .systemFont(ofSize: 11)
        mechanism.textColor = .secondaryLabelColor

        let energy = NSTextField(labelWithString: spec.energy.rawValue)
        energy.font = .systemFont(ofSize: 10, weight: .bold)
        energy.textColor = spec.energy.color

        let titleRow = NSStackView(views: [title])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        if spec.shipping {
            let shipping = NSTextField(labelWithString: "IN SIDEBAR")
            shipping.font = .systemFont(ofSize: 9, weight: .heavy)
            shipping.textColor = .controlAccentColor
            titleRow.addArrangedSubview(shipping)
        }
        titleRow.addArrangedSubview(NSView())
        titleRow.addArrangedSubview(energy)

        let textStack = NSStackView(views: [titleRow, mechanism])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        for child in [well, textStack] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            well.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            well.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            well.widthAnchor.constraint(equalToConstant: 56),
            well.heightAnchor.constraint(equalToConstant: 56),
            spinner.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 22),
            spinner.heightAnchor.constraint(equalToConstant: 22),
            textStack.leadingAnchor.constraint(equalTo: well.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            titleRow.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 76),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
#endif
