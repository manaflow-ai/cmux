public import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign
public import CmuxNextSettings
import os

/// The first-run import card (RFD 0125 D4): the source browser and profile,
/// the cmux profile it lands in (New Profile or one the person has), the kinds
/// with D4's defaults, the stated cookie replacement, and the mirror line that
/// shows `browser.import.cookieSync`. Native AppKit on the shared card glass
/// (`Glass.makeSurface(.card)`). It holds no import logic: Import hands the plan
/// back, and the app runs the existing importer.
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
    private let importButton = ThemedDefaultButton(title: OnboardingStrings.importButton, target: nil, action: nil)

    /// `icon` is the source browser's app icon (``InstalledImportBrowser/icon``), when known.
    public init(plan: FirstRunImportPlan, icon: NSImage?) {
        self.plan = plan
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 10))
        setAccessibilityRole(.group)
        setAccessibilityLabel(OnboardingStrings.firstRunImportTitle(plan.browser.displayName))
        build(icon: icon)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Build

    private func build(icon: NSImage?) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space2
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let glass = Glass.makeSurface(.card, cornerRadius: Metrics.surfaceCornerRadius)
        addSubview(glass)
        addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        let into = row(OnboardingStrings.importInto, destination)
        stack.addArrangedSubview(into)

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
        stack.setCustomSpacing(Metrics.space3, after: into)
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
        let notNow = ThemedBezelButton(title: OnboardingStrings.computerUseNotNow, target: self, action: #selector(dismiss))
        notNow.keyHint = .escape
        importButton.keyHint = .return
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

    // MARK: Presenting

    /// Shows the card centered near the top of `host` (a browser page's chrome), replacing one
    /// already there. Not Now and Import remove it; Import then calls `onImport`. A click on the
    /// mirror switch writes `browser.import.cookieSync` to `settings`, the only write the card makes.
    @discardableResult
    public static func present(on host: NSView, plan: FirstRunImportPlan, icon: NSImage?, settings: SettingsController?,
                               onImport: @escaping (FirstRunImportPlan) -> Void) -> FirstRunImportCardView {
        for old in host.subviews where old is FirstRunImportCardView { old.removeFromSuperview() }
        let card = FirstRunImportCardView(plan: plan, icon: icon)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.onDismiss = { [weak card] in card?.removeFromSuperview() }
        card.onImport = { [weak card] plan in
            card?.removeFromSuperview()
            onImport(plan)
        }
        card.onMirrorChange = { on in
            guard let settings else { return }
            let writer = SettingWriter.currentRun()
            // task-owner: one cmux.json write the person asked for; settings `follow` applies it
            Task {
                do { try await settings.setSetting(at: BrowserCookieSyncSetting.configPath, to: .bool(on), by: writer) } catch {
                    Logger(subsystem: "com.cmuxterm.app.next", category: "browser-import")
                        .error("browser.import.cookieSync write failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            card.topAnchor.constraint(equalTo: host.topAnchor, constant: 64),
        ])
        return card
    }

    /// The card on `host`, if one is shown.
    public static func shown(on host: NSView) -> FirstRunImportCardView? {
        host.subviews.lazy.compactMap { $0 as? FirstRunImportCardView }.first
    }
}
