import AppKit

/// Table rows: each profile is a row with its checkbox on the right edge,
/// hairlines between; the kinds sit under it as one small, quiet line.
struct ImportTableRows: OnboardingScreenVariant {
    static let id = "importData.tableRows"
    static let step = OnboardingModel.Step.importData
    static let name = "Table Rows"
    static let summary = "Rows with right-aligned checkboxes; kinds as a quiet line."
    static let surface = OnboardingSurface.opaque
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.importer
        let list = ImportProfileList(model: model, style: .rows)
        let kinds = ImportKindPicker(model: model, style: .quiet)
        let notes = ImportNotes(model: model)
        let body = VariantLayout.column([list, kinds, notes], spacing: 16, fill: [list, notes])
        var style = OnboardingScaffold.Style()
        style.margin = 48
        style.bodyGap = 20
        style.glassContinue = false
        return OnboardingScaffold.make(title: OnboardingStrings.importTitle, subtitle: ImportVariantStrings.sentenceLocal,
                                       body: body, context: context, style: style)
    }
}
