import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// One control: "From [All Browsers]" centered under a large title; the
/// kinds read as plain text under it. Picking a profile imports only it.
struct ImportSingleMenu: OnboardingScreenVariant {
    static let id = "importData.singleMenu"
    static let step = OnboardingModel.Step.importData
    static let name = "Single Menu"
    static let summary = "One pop-up: all browsers or one profile; kinds as text."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        var style = OnboardingScaffold.Style()
        style.alignment = .center
        style.titleSize = 34
        style.titleTop = 88
        style.margin = 64
        style.bodyGap = 40
        return OnboardingScaffold.make(title: OnboardingStrings.importTitle, subtitle: nil,
                                       body: ImportSingleMenuBody(model: context.model.importer), context: context, style: style)
    }
}

/// "From" + the pop-up, the kinds line, and the calm line when empty.
final class ImportSingleMenuBody: NSView {
    private let model: ImportStepModel
    private let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let row: NSStackView
    private let kinds = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textTertiary)
    private let empty = OnboardingLabel.make(color: Palette.textTertiary)
    private var shown: [BrowserSourceProfile]?
    private var loop: RenderLoop?

    init(model: ImportStepModel) {
        self.model = model
        row = NSStackView(views: [OnboardingLabel.make(ImportVariantStrings.from, color: Palette.textSecondary), popUp])
        super.init(frame: .zero)
        popUp.controlSize = .large
        popUp.target = self
        popUp.action = #selector(picked)
        row.spacing = 12
        let notes = ImportNotes(model: model, centered: true)
        let column = VariantLayout.column([row, kinds, empty, notes], spacing: 12, fill: [notes], alignment: .centerX)
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func picked() {
        let index = popUp.indexOfSelectedItem
        // Item 0 is All Browsers, item 1 the separator, then the profiles.
        ImportKit.selectOnly(model, index >= 2 && index - 2 < model.profiles.count ? model.profiles[index - 2] : nil)
    }

    private func render() {
        let profiles = model.profiles
        if profiles != shown {
            shown = profiles
            popUp.removeAllItems()
            popUp.addItem(withTitle: ImportVariantStrings.allBrowsers)
            popUp.menu?.addItem(.separator())
            for profile in profiles { popUp.menu?.addItem(withTitle: OnboardingStrings.profileName(profile), action: nil, keyEquivalent: "") }
        }
        let selected = profiles.filter { model.isSelected($0) }
        let index = selected.count == 1 && profiles.count > 1 ? (profiles.firstIndex(of: selected[0]) ?? -2) + 2 : 0
        if popUp.indexOfSelectedItem != index { popUp.selectItem(at: index) }
        popUp.isEnabled = model.canEditSelection
        let emptyText = ImportKit.emptyText(model)
        empty.stringValue = emptyText ?? ""
        empty.isHidden = emptyText == nil
        row.isHidden = emptyText != nil
        kinds.stringValue = ImportKit.kindsText(model)
        kinds.isHidden = emptyText != nil
    }
}
