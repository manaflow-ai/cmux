import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// Step 2: sources on the left, choices and progress on the right.
final class ImportStepView: NSView {
    init(model: ImportStepModel) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let sources = ImportSourceList(model: model)
        let panel = ImportPanelView(model: model)
        let divider = ThemedView()
        divider.fill = { Palette.separator }
        addSubview(sources)
        addSubview(divider)
        addSubview(panel)
        NSLayoutConstraint.activate([
            sources.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -Metrics.space3),
            sources.topAnchor.constraint(equalTo: topAnchor), sources.bottomAnchor.constraint(equalTo: bottomAnchor),
            sources.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5),
            divider.leadingAnchor.constraint(equalTo: sources.trailingAnchor, constant: Metrics.space6),
            divider.topAnchor.constraint(equalTo: topAnchor), divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            panel.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: Metrics.space6 + Metrics.space2),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor), panel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Safari's data is behind Full Disk Access: say so, link to the pane, and
/// check again after the user flips the switch. Never asks silently.
final class FullDiskAccessNotice: ThemedView {
    init(model: ImportStepModel) {
        super.init(frame: .zero)
        fill = { Palette.hoverFill }
        cornerRadius = OnboardingMetrics.itemRadius + 2
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Palette.attention
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = OnboardingLabel.make(OnboardingStrings.fullDiskAccessTitle, font: Typography.bodyEmphasized)
        let detail = OnboardingLabel.make(OnboardingStrings.fullDiskAccessDetail, font: Typography.caption, color: Palette.textTertiary, lines: 3)
        let open = OnboardingButton(OnboardingStrings.openSystemSettings, style: .secondary) { [weak model] in model?.openFullDiskAccessSettings() }
        let recheck = OnboardingButton(OnboardingStrings.checkAgain, style: .plain) { [weak model] in model?.redetect() }
        let buttons = NSStackView(views: [open, recheck])
        buttons.spacing = Metrics.space3
        let text = NSStackView(views: [title, detail, buttons])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.space3
        text.setCustomSpacing(Metrics.space4, after: detail)
        let row = NSStackView(views: [icon, text])
        row.alignment = .top
        row.spacing = Metrics.space4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let pad = Metrics.space5
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            row.topAnchor.constraint(equalTo: topAnchor, constant: pad), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            detail.widthAnchor.constraint(equalTo: text.widthAnchor),
        ])
    }
}

/// A toggle chip: filled when on.
final class ChipToggle: SelectableCard {
    var onToggle: (() -> Void)?
    var isOn = false { didSet { isSelected = isOn; glyph.isHidden = !isOn } }
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.45 } }
    private let glyph = NSImageView()

    init(title: String) {
        super.init(frame: .zero)
        glyph.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Metrics.smallIconSize - 2, weight: .semibold))
        glyph.contentTintColor = Palette.textPrimary
        glyph.isHidden = true
        let label = OnboardingLabel.make(title, font: Typography.body)
        let stack = NSStackView(views: [glyph, label])
        stack.spacing = Metrics.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space5),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space5),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: OnboardingMetrics.buttonHeight),
        ])
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        onSelect = { [weak self] in
            guard let self, isEnabled else { return }
            onToggle?()
        }
    }

    override func layout() {
        super.layout()
        cornerRadius = bounds.height / 2
    }
}
