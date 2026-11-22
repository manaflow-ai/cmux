import AppKit

/// Two columns under a small title: browsers on the left, what to bring on
/// the right, a hairline between. Dense, 32 pt margins.
struct ImportSplit: OnboardingScreenVariant {
    static let id = "importData.split"
    static let step = OnboardingModel.Step.importData
    static let name = "Two Columns"
    static let summary = "Browsers left, what to bring right; small title, dense."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.importer
        let list = ImportProfileList(model: model, style: .checkboxes)
        let left = VariantLayout.column([VariantLayout.header(ImportVariantStrings.browsers), list], spacing: 12, fill: [list])
        let right = VariantLayout.column([VariantLayout.header(ImportVariantStrings.bring), ImportKindPicker(model: model, style: .vertical)],
                                         spacing: 12)
        let divider = VariantLayout.hairline(vertical: true)
        let notes = ImportNotes(model: model)
        let body = NSView()
        for view in [left, divider, right, notes] { body.addSubview(view) }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: body.leadingAnchor), left.topAnchor.constraint(equalTo: body.topAnchor),
            left.bottomAnchor.constraint(equalTo: notes.topAnchor, constant: -16),
            divider.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 24),
            divider.topAnchor.constraint(equalTo: body.topAnchor), divider.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            right.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 24),
            right.trailingAnchor.constraint(equalTo: body.trailingAnchor), right.topAnchor.constraint(equalTo: body.topAnchor),
            right.widthAnchor.constraint(equalToConstant: 168),
            right.bottomAnchor.constraint(lessThanOrEqualTo: notes.topAnchor, constant: -16),
            notes.leadingAnchor.constraint(equalTo: body.leadingAnchor), notes.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            notes.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
        var style = OnboardingScaffold.Style()
        style.titleSize = 17
        style.margin = 32
        style.titleTop = 48
        style.bodyGap = 24
        return OnboardingScaffold.make(title: OnboardingStrings.importTitle, subtitle: ImportVariantStrings.sentencePick,
                                       body: body, context: context, style: style)
    }
}
