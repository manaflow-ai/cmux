import AppKit
import CmuxNextDesign

/// The small print under an import screen: progress or the Keychain note,
/// and the Full Disk Access row when Safari needs it. Hidden when empty.
final class ImportNotes: NSStackView {
    private let model: ImportStepModel
    private let note: NSTextField
    private let access = NSStackView()
    private var loop: RenderLoop?

    init(model: ImportStepModel, centered: Bool = false) {
        self.model = model
        note = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textTertiary, lines: 2)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .vertical
        alignment = centered ? .centerX : .leading
        spacing = 12
        if centered { note.alignment = .center }
        let open = OnboardingControl.button(OnboardingStrings.openSystemSettings, target: self, action: #selector(openSettings))
        open.controlSize = .regular
        let recheck = OnboardingControl.plainButton(OnboardingStrings.checkAgain, target: self, action: #selector(recheck))
        access.setViews([OnboardingLabel.make(OnboardingStrings.fullDiskAccessTitle, color: Palette.textSecondary), open, recheck], in: .leading)
        access.spacing = 12
        addArrangedSubview(note)
        addArrangedSubview(access)
        note.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func openSettings() { model.openFullDiskAccessSettings() }
    @objc private func recheck() { model.redetect() }

    private func render() {
        let text = ImportKit.noteText(model)
        note.stringValue = text
        note.isHidden = text.isEmpty
        access.isHidden = !model.needsFullDiskAccess
    }
}
