import AppKit
import CmuxNextDesign

/// Editorial split: a large wrapping title and the sentence in a narrow
/// left column; the rows and kinds in the right column, top-aligned.
struct ImportEditorial: OnboardingScreenVariant {
    static let id = "importData.editorial"
    static let step = OnboardingModel.Step.importData
    static let name = "Editorial"
    static let summary = "Big wrapping title left, rows right; no transition."
    static let surface = OnboardingSurface.opaque
    static let transition = OnboardingTransition.none

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.importer
        let root = FlippedView()
        let title = OnboardingLabel.make(ImportVariantStrings.titleBring, font: .systemFont(ofSize: 34, weight: .bold), lines: 3)
        let sentence = OnboardingLabel.make(ImportVariantStrings.sentenceLocal, color: Palette.textSecondary, lines: 3)
        let list = ImportProfileList(model: model, style: .rows)
        let kinds = ImportKindPicker(model: model, style: .vertical)
        let notes = ImportNotes(model: model)
        let right = VariantLayout.column([list, VariantLayout.header(ImportVariantStrings.bring), kinds, notes], spacing: 12,
                                         fill: [list, notes])
        if let stack = right.subviews.first as? NSStackView { stack.setCustomSpacing(28, after: list) }
        let footer = OnboardingFooter(context: context, glassContinue: false)
        for view in [title, sentence, right, footer] { root.addSubview(view) }
        let margin: CGFloat = 48
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 60),
            title.widthAnchor.constraint(equalToConstant: 200),
            sentence.leadingAnchor.constraint(equalTo: title.leadingAnchor), sentence.widthAnchor.constraint(equalTo: title.widthAnchor),
            sentence.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            right.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 40),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            // The first row's text lines up with the title's first baseline region.
            right.topAnchor.constraint(equalTo: root.topAnchor, constant: 60),
            right.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28),
        ])
        return root
    }
}
