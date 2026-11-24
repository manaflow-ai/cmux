public import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// The first-run import card (RFD 0125 D4): the source browser and profile,
/// the cmux profile it lands in (New Profile or one the person has), the kinds
/// with D4's defaults, the stated cookie replacement, and the mirror line that
/// shows `browser.import.cookieSync`. Native AppKit on an opaque surface, so it
/// reads the same in a still (the gallery) as on screen. It holds no import
/// logic: Import hands the plan back, and the app runs the existing importer.
@MainActor
public final class FirstRunImportCardView: NSView {
    /// The plan as the person left it, after every click.
    public private(set) var plan: FirstRunImportPlan
    /// Called on Import with the plan to run.
    public var onImport: ((FirstRunImportPlan) -> Void)?
    /// Called on Not Now.
    public var onDismiss: (() -> Void)?
    /// Called when the mirror switch is clicked, with its new state: the app writes `browser.import.cookieSync`.
    public var onMirrorChange: ((Bool) -> Void)?

    static let width: CGFloat = 360

    private let stack = NSStackView()
    private let destination = NSPopUpButton(frame: .zero, pullsDown: false)
    private var checkboxes: [ImportDataKind: NSButton] = [:]
    private let replaceLine = OnboardingLabel.make(OnboardingStrings.firstRunImportReplacesCookies,
                                                   font: Typography.system(size: TypeScale.caption), color: Palette.textSecondary, lines: 0)
    private let mirrorRow = NSStackView()
    private let mirrorSwitch = NSSwitch()
    private let importButton = NSButton()

    /// `icon` is the source browser's app icon (``InstalledImportBrowser/icon``), when known.
    public init(plan: FirstRunImportPlan, icon: NSImage?) {
        self.plan = plan
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 10))
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = Metrics.surfaceCornerRadius
        setAccessibilityRole(.group)
        setAccessibilityLabel(OnboardingStrings.firstRunImportTitle(plan.browser.displayName))
        build(icon: icon)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var wantsUpdateLayer: Bool { true }

    override public func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.elevatedBackground.cgColor
            layer?.borderColor = Palette.textPrimary.withAlphaComponent(CardSurfaceView.lightEdgeShare).cgColor
            layer?.borderWidth = 1 / max(window?.backingScaleFactor ?? 2, 1)
        }
    }

    // MARK: Build

    private func build(icon: NSImage?) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space2
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])

        let title = OnboardingLabel.make(OnboardingStrings.firstRunImportTitle(plan.browser.displayName),
                                         font: Typography.system(size: TypeScale.title, weight: .semibold))
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(Metrics.space3, after: title)

        // From: the source browser's icon and profile.
        let source = OnboardingLabel.make(plan.sourceProfile)
        var fromViews: [NSView] = []
        if let icon {
            let image = NSImageView(image: icon)
            image.translatesAutoresizingMaskIntoConstraints = false
            image.widthAnchor.constraint(equalToConstant: 16).isActive = true
            image.heightAnchor.constraint(equalToConstant: 16).isActive = true
            fromViews.append(image)
        }
        fromViews.append(source)
        stack.addArrangedSubview(row(OnboardingStrings.firstRunImportFrom, NSStackView(views: fromViews)))

        // Import Into: New Profile, then the person's profiles.
        destination.addItems(withTitles: [OnboardingStrings.newMatchingProfile] + plan.profiles.map(\.name))
        destination.target = self
        destination.action = #selector(destinationChanged)
        destination.controlSize = .small
        destination.font = Typography.system(size: TypeScale.body)
        destination.setAccessibilityLabel(OnboardingStrings.importInto)
        stack.addArrangedSubview(row(OnboardingStrings.importInto, destination))

        // The kinds, in D4's order.
        let kinds = NSStackView()
        kinds.orientation = .vertical
        kinds.alignment = .leading
        kinds.spacing = Metrics.space1
        for kind in FirstRunImportPlan.kindOrder {
            let box = NSButton(checkboxWithTitle: OnboardingStrings.kind(kind), target: self, action: #selector(kindToggled(_:)))
            box.font = Typography.system(size: TypeScale.body)
            box.tag = FirstRunImportPlan.kindOrder.firstIndex(of: kind) ?? 0
            checkboxes[kind] = box
            kinds.addArrangedSubview(box)
        }
        stack.setCustomSpacing(Metrics.space3, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(kinds)

        // Stated at the decision: Sign-ins into a profile that has cookies replace them.
        replaceLine.preferredMaxLayoutWidth = Self.width - 32
        replaceLine.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(replaceLine)
        replaceLine.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        // The mirror line, for Chromium sources (cookie sync reads Chromium stores only).
        mirrorSwitch.controlSize = .mini
        mirrorSwitch.target = self
        mirrorSwitch.action = #selector(mirrorToggled)
        mirrorSwitch.setAccessibilityLabel(OnboardingStrings.firstRunImportMirror(plan.browser.displayName))
        let mirrorText = NSStackView(views: [
            OnboardingLabel.make(OnboardingStrings.firstRunImportMirror(plan.browser.displayName)),
            {
                let detail = OnboardingLabel.make(OnboardingStrings.firstRunImportMirrorDetail,
                                                  font: Typography.system(size: TypeScale.caption), color: Palette.textSecondary, lines: 0)
                detail.preferredMaxLayoutWidth = Self.width - 32 - 40
                detail.setContentCompressionResistancePriority(.required, for: .vertical)
                return detail
            }(),
        ])
        mirrorText.orientation = .vertical
        mirrorText.alignment = .leading
        mirrorText.spacing = 2
        mirrorRow.setViews([mirrorText, mirrorSwitch], in: .leading)
        mirrorRow.orientation = .horizontal
        mirrorRow.alignment = .top
        mirrorRow.spacing = Metrics.space2
        stack.setCustomSpacing(Metrics.space3, after: replaceLine)
        stack.addArrangedSubview(mirrorRow)
        mirrorRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        // Not Now and Import, trailing.
        let notNow = NSButton(title: OnboardingStrings.computerUseNotNow, target: self, action: #selector(dismiss))
        notNow.bezelStyle = .push
        notNow.keyEquivalent = "\u{1b}"
        importButton.title = OnboardingStrings.importButton
        importButton.bezelStyle = .push
        importButton.keyEquivalent = "\r"
        importButton.target = self
        importButton.action = #selector(runImport)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, notNow, importButton])
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.space2
        stack.setCustomSpacing(Metrics.space4, after: mirrorRow)
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    }

    /// A labeled row: the label in secondary text at a fixed width, then the control.
    private func row(_ label: String, _ control: NSView) -> NSView {
        let name = OnboardingLabel.make(label, color: Palette.textSecondary)
        name.widthAnchor.constraint(equalToConstant: 84).isActive = true
        let row = NSStackView(views: [name, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space2
        return row
    }

    // MARK: State

    private func render() {
        destination.selectItem(at: plan.destinationIndex)
        for (kind, box) in checkboxes { box.state = plan.kinds.contains(kind) ? .on : .off }
        replaceLine.isHidden = !plan.replacesCookies
        mirrorRow.isHidden = !plan.offersMirror
        mirrorSwitch.state = plan.mirrorOn ? .on : .off
        mirrorSwitch.isEnabled = plan.kinds.contains(.cookies)
        importButton.isEnabled = plan.canImport
    }

    @objc private func destinationChanged() {
        plan.selectDestination(at: destination.indexOfSelectedItem)
        render()
    }

    @objc private func kindToggled(_ sender: NSButton) {
        guard FirstRunImportPlan.kindOrder.indices.contains(sender.tag) else { return }
        plan.toggle(FirstRunImportPlan.kindOrder[sender.tag])
        render()
    }

    @objc private func mirrorToggled() {
        plan.mirrorOn = mirrorSwitch.state == .on
        onMirrorChange?(plan.mirrorOn)
        render()
    }

    @objc private func dismiss() { onDismiss?() }

    @objc private func runImport() {
        guard plan.canImport else { return }
        onImport?(plan)
    }
}
