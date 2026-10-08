import AppKit
import CmuxNextDesign

/// The choice as one sentence ("4 of 4 profiles", then the kinds) with an
/// Edit disclosure that opens the checkboxes. Editorial, 56 pt margins.
struct ImportSummaryLine: OnboardingScreenVariant {
    static let id = "importData.summary"
    static let step = OnboardingModel.Step.importData
    static let name = "Summary Line"
    static let summary = "The plan as one line; Edit opens the checkboxes."
    static let surface = OnboardingSurface.opaque
    static let transition = OnboardingTransition.crossfade

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        var style = OnboardingScaffold.Style()
        style.titleSize = 28
        style.titleWeight = .bold
        style.margin = 56
        style.titleTop = 64
        style.bodyGap = 40
        style.glassContinue = false
        return OnboardingScaffold.make(title: OnboardingStrings.importTitle, subtitle: nil,
                                       body: ImportSummaryBody(model: context.model.importer), context: context, style: style)
    }
}

/// The summary, the disclosure and the editors it opens.
final class ImportSummaryBody: NSView {
    private let model: ImportStepModel
    private let headline = OnboardingLabel.make(font: .systemFont(ofSize: 17, weight: .medium))
    private let detail = OnboardingLabel.make(color: Palette.textSecondary)
    private var disclosure: NSButton!
    private var edit: NSButton!
    private let editors: NSView
    private var loop: RenderLoop?

    init(model: ImportStepModel) {
        self.model = model
        let list = ImportProfileList(model: model, style: .checkboxes, spacing: 10)
        let kinds = ImportKindPicker(model: model, style: .inline)
        editors = VariantLayout.column([list, VariantLayout.hairline(), kinds], spacing: 16, fill: [list])
        super.init(frame: .zero)
        disclosure = NSButton(title: "", target: self, action: #selector(disclose))
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.contentTintColor = Palette.textSecondary
        disclosure.setAccessibilityLabel(ImportVariantStrings.edit)
        edit = OnboardingControl.plainButton(ImportVariantStrings.edit, target: self, action: #selector(discloseFromLabel))
        let editRow = NSStackView(views: [disclosure, edit])
        editRow.spacing = 4
        editors.isHidden = true
        let notes = ImportNotes(model: model)
        let column = VariantLayout.column([headline, detail, editRow, editors, notes], spacing: 8, fill: [editors, notes])
        if let stack = column.subviews.first as? NSStackView {
            stack.setCustomSpacing(20, after: detail)
            stack.setCustomSpacing(16, after: editRow)
            stack.setCustomSpacing(20, after: editors)
        }
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func disclose() { editors.isHidden = disclosure.state != .on }
    @objc private func discloseFromLabel() {
        disclosure.state = disclosure.state == .on ? .off : .on
        disclose()
    }

    private func render() {
        let empty = ImportKit.emptyText(model)
        headline.stringValue = empty ?? ImportKit.countText(model)
        headline.textColor = empty == nil ? Palette.textPrimary : Palette.textTertiary
        detail.stringValue = ImportKit.kindsText(model)
        detail.isHidden = empty != nil
        disclosure.superview?.isHidden = empty != nil
        if empty != nil { editors.isHidden = true }
        else { editors.isHidden = disclosure.state != .on }
    }
}
