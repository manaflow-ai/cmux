import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// What to bring (bookmarks, history, sign-ins) as system controls:
/// a row of checkboxes, a quieter small row, a column, or three large
/// glass toggle buttons. Every shape tints in theme neutrals.
final class ImportKindPicker: NSStackView {
    enum Style { case inline, quiet, vertical, toggles }

    private let model: ImportStepModel
    private let style: Style
    private var controls: [ImportDataKind: NSButton] = [:]
    private var loop: RenderLoop?

    init(model: ImportStepModel, style: Style) {
        self.model = model
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = style == .vertical ? .vertical : .horizontal
        alignment = style == .vertical ? .leading : .centerY
        spacing = switch style {
        case .inline: 20
        case .quiet: 16
        case .vertical: 12
        case .toggles: 12
        }
        if style == .toggles { distribution = .fillEqually } else { setHuggingPriority(.defaultHigh, for: .horizontal) }
        for (index, kind) in ImportStepModel.offeredKinds.enumerated() {
            let control = makeControl(OnboardingStrings.kind(kind))
            control.tag = index
            controls[kind] = control
            addArrangedSubview(control)
        }
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func toggled(_ sender: NSButton) { model.toggle(ImportStepModel.offeredKinds[sender.tag]) }

    private func makeControl(_ title: String) -> NSButton {
        switch style {
        case .toggles:
            let button = OnboardingControl.button(title, target: self, action: #selector(toggled(_:)))
            button.bezelStyle = .glass
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.setAccessibilityRole(.checkBox)
            return button
        case .quiet:
            let box = OnboardingControl.checkbox(title, target: self, action: #selector(toggled(_:)))
            box.controlSize = .small
            box.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.textSecondary,
            ])
            return box
        case .inline, .vertical:
            return OnboardingControl.checkbox(title, target: self, action: #selector(toggled(_:)))
        }
    }

    private func render() {
        let editable = model.canEditSelection
        // With no profiles there is nothing to bring: only the calm line shows.
        isHidden = ImportKit.emptyText(model) != nil
        for (kind, control) in controls {
            let on = model.kinds.contains(kind)
            control.isEnabled = editable
            guard style == .toggles else {
                control.state = on ? .on : .off
                continue
            }
            // A momentary glass button drawn as a toggle: filled and checked when
            // on, a quiet plus when off (an always-present symbol keeps the title still).
            control.bezelColor = on ? Palette.selectionFill : nil
            control.image = NSImage(systemSymbolName: on ? "checkmark" : "plus", accessibilityDescription: nil)
            control.contentTintColor = on ? Palette.textPrimary : Palette.textTertiary
            control.attributedTitle = NSAttributedString(string: OnboardingStrings.kind(kind), attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: on ? Palette.textPrimary : Palette.textTertiary,
            ])
            control.setAccessibilityValue(on ? 1 : 0)
        }
    }
}
