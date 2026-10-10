import AppKit
import CmuxNextDesign

/// Compact checklist for classic workspaces found on disk.
final class ClassicSessionsStepView: NSView {
    private let model: ClassicSessionsStepModel
    private let list = NSStackView()
    private let status = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textTertiary, lines: 2)
    private var rendered = false
    private var loop: RenderLoop?

    init(model: ClassicSessionsStepModel) {
        self.model = model
        super.init(frame: .zero)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false; status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(list); addSubview(status)
        NSLayoutConstraint.activate([list.leadingAnchor.constraint(equalTo: leadingAnchor), list.trailingAnchor.constraint(equalTo: trailingAnchor), list.topAnchor.constraint(equalTo: topAnchor), status.leadingAnchor.constraint(equalTo: leadingAnchor), status.trailingAnchor.constraint(equalTo: trailingAnchor), status.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 12), status.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func render() {
        if !rendered, model.scanned { rendered = true; for workspace in model.workspaces { let row = NSButton(checkboxWithTitle: workspace.name, target: self, action: #selector(toggle(_:))); row.tag = model.workspaces.firstIndex(of: workspace) ?? 0; row.state = model.isSelected(workspace) ? .on : .off; row.toolTip = workspace.workingDirectory; list.addArrangedSubview(row) } }
        status.stringValue = model.isScanning ? OnboardingStrings.classicSessionsScanning
            : (model.scanError != nil ? OnboardingStrings.classicSessionsError
               : (model.workspaces.isEmpty && model.scanned ? OnboardingStrings.classicSessionsEmpty : ""))
    }
    @objc private func toggle(_ sender: NSButton) { guard model.workspaces.indices.contains(sender.tag) else { return }; model.toggle(model.workspaces[sender.tag]) }
}
