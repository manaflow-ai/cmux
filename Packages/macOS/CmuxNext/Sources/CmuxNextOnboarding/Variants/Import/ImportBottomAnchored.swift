import AppKit

/// A large title alone at the top; the rows and kinds sit low, just above
/// the footer, so the eye moves title, then choice, then Continue.
struct ImportBottomAnchored: OnboardingScreenVariant {
    static let id = "importData.bottomAnchored"
    static let step = OnboardingModel.Step.importData
    static let name = "Bottom Anchored"
    static let summary = "Big title on top; rows and kinds sit just above the footer."
    static let surface = OnboardingSurface.glassPanel
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.importer
        let list = ImportProfileList(model: model, style: .rows)
        let kinds = ImportKindPicker(model: model, style: .inline)
        let notes = ImportNotes(model: model)
        let body = VariantLayout.column([list, kinds, notes], spacing: 20, fill: [list, notes], anchoredToBottom: true)
        var style = OnboardingScaffold.Style()
        style.titleSize = 34
        style.titleWeight = .bold
        style.margin = 48
        style.titleTop = 48
        style.bodyGap = 24
        return OnboardingScaffold.make(title: ImportVariantStrings.titleShort, subtitle: ImportVariantStrings.sentenceLocal,
                                       body: body, context: context, style: style)
    }
}
