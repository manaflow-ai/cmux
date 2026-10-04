import AppKit
import CmuxNextDesign

/// Profiles grouped by browser in an inset opaque well: one row per
/// browser, its profiles as checkboxes on the right.
struct ImportGrouped: OnboardingScreenVariant {
    static let id = "importData.grouped"
    static let step = OnboardingModel.Step.importData
    static let name = "Grouped Well"
    static let summary = "One row per browser in an inset well, profiles beside it."
    static let surface = OnboardingSurface.glassControls
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.importer
        let well = ThemedView()
        well.fill = { Palette.contentBackground }
        well.border = { Palette.paneBorder }
        well.cornerRadius = 12
        let list = ImportProfileList(model: model, style: .grouped)
        well.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 16),
            list.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -16),
            list.topAnchor.constraint(equalTo: well.topAnchor, constant: 4),
            list.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -4),
            well.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        let kinds = ImportKindPicker(model: model, style: .inline)
        let notes = ImportNotes(model: model)
        let body = VariantLayout.column([well, kinds, notes], spacing: 20, fill: [well, notes])
        var style = OnboardingScaffold.Style()
        style.bodyGap = 24
        return OnboardingScaffold.make(title: ImportVariantStrings.titleShort, subtitle: OnboardingStrings.importSubtitle,
                                       body: body, context: context, style: style)
    }
}
