import AppKit

@MainActor
final class SettingsDetailViewController: NSViewController {
    var section: SettingsSection {
        didSet { refreshSection() }
    }

    private let titleField = NSTextField(labelWithString: "")
    private let sectionValueField = NSTextField(labelWithString: "")
    private let enabledSwitch = NSSwitch()
    private let modeControl = NSSegmentedControl(
        labels: SettingsDetailMode.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let amountSlider = NSSlider(value: 12, minValue: 0, maxValue: 24, target: nil, action: nil)

    init(section: SettingsSection) {
        self.section = section
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()

        titleField.font = .systemFont(ofSize: 20, weight: .semibold)
        titleField.setAccessibilityIdentifier("settings.detail.title")

        let sectionRow = labeledRow(
            title: String(localized: "detail.section", defaultValue: "Section"),
            control: sectionValueField
        )
        let toggleRow = labeledRow(
            title: String(localized: "detail.toggle", defaultValue: "Enable"),
            control: enabledSwitch
        )
        let modeRow = labeledRow(
            title: String(localized: "detail.mode", defaultValue: "Mode"),
            control: modeControl
        )
        let sliderRow = labeledRow(
            title: String(localized: "detail.slider", defaultValue: "Amount"),
            control: amountSlider
        )

        enabledSwitch.state = .on
        modeControl.selectedSegment = SettingsDetailMode.allCases.firstIndex(of: .system) ?? 0
        amountSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let primaryButton = NSButton(
            title: String(localized: "detail.primaryAction", defaultValue: "Open Related File"),
            target: nil,
            action: nil
        )
        primaryButton.isEnabled = false
        let secondaryButton = NSButton(
            title: String(localized: "detail.secondaryAction", defaultValue: "Restore Defaults"),
            target: nil,
            action: nil
        )
        secondaryButton.isEnabled = false
        let actions = NSStackView(views: [primaryButton, secondaryButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        let form = NSStackView(views: [titleField, sectionRow, toggleRow, modeRow, sliderRow, actions])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 16
        form.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(form)

        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            form.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
            form.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
        ])

        refreshSection()
    }

    private func labeledRow(title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func refreshSection() {
        guard isViewLoaded else { return }
        titleField.stringValue = section.title
        sectionValueField.stringValue = section.title
    }
}

private enum SettingsDetailMode: String, CaseIterable {
    case system
    case compact
    case expanded

    var title: String {
        switch self {
        case .system:
            String(localized: "mode.system", defaultValue: "System")
        case .compact:
            String(localized: "mode.compact", defaultValue: "Compact")
        case .expanded:
            String(localized: "mode.expanded", defaultValue: "Expanded")
        }
    }
}
