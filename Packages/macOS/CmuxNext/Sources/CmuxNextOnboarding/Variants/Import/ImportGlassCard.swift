import AppKit
import CmuxNextDesign

/// Opaque window, one centered glass card: profile rows on top, the kinds
/// in the card's lower band. Title and sentence centered above it.
struct ImportGlassCard: OnboardingScreenVariant {
    static let id = "importData.glassCard"
    static let step = OnboardingModel.Step.importData
    static let name = "Glass Card"
    static let summary = "One centered glass card holding the rows and the kinds."
    static let surface = OnboardingSurface.glassControls
    static let transition = OnboardingTransition.crossfade

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.importer
        let inner = NSView()
        let list = ImportProfileList(model: model, style: .rows)
        let line = VariantLayout.hairline()
        let kinds = ImportKindPicker(model: model, style: .quiet)
        line.translatesAutoresizingMaskIntoConstraints = false
        for view in [list, line, kinds] { inner.addSubview(view) }
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: inner.topAnchor, constant: 4),
            list.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 20),
            list.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -20),
            line.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 4),
            line.leadingAnchor.constraint(equalTo: inner.leadingAnchor), line.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            kinds.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 12),
            kinds.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 20),
            kinds.trailingAnchor.constraint(lessThanOrEqualTo: inner.trailingAnchor, constant: -20),
            kinds.bottomAnchor.constraint(equalTo: inner.bottomAnchor, constant: -12),
        ])
        let card = Glass.makePanel(content: inner, cornerRadius: 12)
        let notes = ImportNotes(model: model, centered: true)
        card.widthAnchor.constraint(equalToConstant: 400).isActive = true
        let body = VariantLayout.column([card, notes], spacing: 16, fill: [notes], alignment: .centerX)
        var style = OnboardingScaffold.Style()
        style.alignment = .center
        style.margin = 44
        style.bodyGap = 24
        return OnboardingScaffold.make(title: ImportVariantStrings.titleBring, subtitle: ImportVariantStrings.sentenceLocal,
                                       body: body, context: context, style: style)
    }
}
