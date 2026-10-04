import AppKit
import CmuxNextDesign

/// One large "Import everything" checkbox, centered; a disclosure under it
/// opens the per-profile list for people who want to choose.
struct ImportEverything: OnboardingScreenVariant {
    static let id = "importData.everything"
    static let step = OnboardingModel.Step.importData
    static let name = "Everything Toggle"
    static let summary = "One big checkbox; a disclosure opens the profile list."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        var style = OnboardingScaffold.Style()
        style.alignment = .center
        style.titleSize = 28
        style.titleTop = 64
        style.margin = 56
        style.bodyGap = 32
        return OnboardingScaffold.make(title: ImportVariantStrings.titleEverything, subtitle: ImportVariantStrings.sentenceLocal,
                                       body: ImportEverythingBody(model: context.model.importer), context: context, style: style)
    }
}

/// The master checkbox (mixed when only part is on), the disclosure and
/// the hidden list, in a narrow centered column.
final class ImportEverythingBody: NSView {
    private let model: ImportStepModel
    private var master: NSButton!
    private var disclosure: NSButton!
    private var disclosureRow: NSView?
    private let list: ImportProfileList
    private var loop: RenderLoop?

    init(model: ImportStepModel) {
        self.model = model
        list = ImportProfileList(model: model, style: .checkboxes, spacing: 10, emptyAlignment: .center)
        super.init(frame: .zero)
        master = OnboardingControl.checkbox(ImportVariantStrings.everything, target: self, action: #selector(masterToggled))
        master.controlSize = .large
        master.allowsMixedState = true
        master.attributedTitle = NSAttributedString(string: ImportVariantStrings.everything, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: Palette.textPrimary,
        ])
        disclosure = NSButton(title: "", target: self, action: #selector(disclose))
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.contentTintColor = Palette.textSecondary
        disclosure.setAccessibilityLabel(ImportVariantStrings.chooseProfiles)
        let label = OnboardingControl.plainButton(ImportVariantStrings.chooseProfiles, target: self, action: #selector(discloseFromLabel))
        let row = NSStackView(views: [disclosure, label])
        row.spacing = 4
        disclosureRow = row
        list.isHidden = true
        let notes = ImportNotes(model: model, centered: true)
        let column = VariantLayout.column([master, row, list, notes], spacing: 16, fill: [list, notes], alignment: .centerX)
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.centerXAnchor.constraint(equalTo: centerXAnchor), column.widthAnchor.constraint(equalToConstant: 280),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func masterToggled() { ImportKit.setEverything(model, on: ImportKit.everythingState(model) != true) }
    @objc private func disclose() { list.isHidden = disclosure.state != .on }
    @objc private func discloseFromLabel() {
        disclosure.state = disclosure.state == .on ? .off : .on
        disclose()
    }

    private func render() {
        let state = ImportKit.everythingState(model)
        master.state = state == true ? .on : (state == false ? .off : .mixed)
        master.isEnabled = model.canEditSelection && !model.profiles.isEmpty
        // With nothing found there is nothing to choose: the calm line shows instead.
        let empty = ImportKit.emptyText(model) != nil
        master.isHidden = empty
        disclosureRow?.isHidden = empty
        if empty { list.isHidden = false }
        else if disclosure.state != .on { list.isHidden = true }
    }
}
