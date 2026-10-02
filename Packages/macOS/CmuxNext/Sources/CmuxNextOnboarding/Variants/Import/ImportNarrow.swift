import AppKit

/// A narrow centered column in a floating glass panel: a question, the
/// profiles, then the kinds as one small centered line.
struct ImportNarrow: OnboardingScreenVariant {
    static let id = "importData.narrow"
    static let step = OnboardingModel.Step.importData
    static let name = "Narrow Column"
    static let summary = "Centered question, a narrow column of profiles, kinds below."
    static let surface = OnboardingSurface.glassPanel
    static let transition = OnboardingTransition.crossfade

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.importer
        let list = ImportProfileList(model: model, style: .checkboxes, spacing: 14, emptyAlignment: .center)
        let kinds = ImportKindPicker(model: model, style: .quiet)
        let notes = ImportNotes(model: model, centered: true)
        let body = NSView()
        let line = VariantLayout.hairline()
        line.translatesAutoresizingMaskIntoConstraints = false
        for view in [list, line, kinds, notes] { body.addSubview(view) }
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: body.topAnchor), list.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            list.widthAnchor.constraint(equalToConstant: 248),
            line.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 20), line.widthAnchor.constraint(equalToConstant: 248),
            line.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            kinds.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 16), kinds.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            kinds.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor),
            notes.topAnchor.constraint(equalTo: kinds.bottomAnchor, constant: 16),
            notes.leadingAnchor.constraint(equalTo: body.leadingAnchor), notes.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            notes.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor),
        ])
        var style = OnboardingScaffold.Style()
        style.alignment = .center
        style.margin = 52
        style.titleTop = 52
        style.bodyGap = 28
        return OnboardingScaffold.make(title: ImportVariantStrings.titleWhich, subtitle: nil, body: body, context: context, style: style)
    }
}
