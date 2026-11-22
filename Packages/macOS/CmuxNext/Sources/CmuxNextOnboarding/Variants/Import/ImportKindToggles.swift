import AppKit
import CmuxNextDesign

/// Three large glass toggles for what to bring, full width; the profiles
/// fold into one pull-down under them. Bold leading title, no transition.
struct ImportKindToggles: OnboardingScreenVariant {
    static let id = "importData.kindToggles"
    static let step = OnboardingModel.Step.importData
    static let name = "Kind Toggles"
    static let summary = "Three large glass toggles; profiles in one pull-down."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.none

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.importer
        let toggles = ImportKindPicker(model: model, style: .toggles)
        let from = OnboardingLabel.make(ImportVariantStrings.from, color: Palette.textSecondary)
        let menu = ImportProfileMenu(model: model)
        let row = NSStackView(views: [from, menu])
        row.spacing = 12
        let notes = ImportNotes(model: model)
        let body = VariantLayout.column([toggles, row, notes], spacing: 28, fill: [toggles, notes])
        var style = OnboardingScaffold.Style()
        style.titleSize = 28
        style.titleWeight = .bold
        style.margin = 48
        style.titleTop = 56
        style.bodyGap = 32
        return OnboardingScaffold.make(title: ImportVariantStrings.titleShort, subtitle: ImportVariantStrings.sentenceBackground,
                                       body: body, context: context, style: style)
    }
}
