import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups

/// The Computer Use window: the helper app's large icon, a title, a short
/// line, a `ComputerUseGrantRow` card per grant, and a footer. Only the next missing
/// row's Allow is filled. Allow opens that list in System Settings with
/// `HelperDragPanel` docked to it; when the grant lands the panel goes, the
/// window comes back to the front, and the next row turns primary
/// (`ComputerUseStepModel`). All done: the line says so and Done closes.
final class ComputerUseSetupView: NSView {
    static let size = NSSize(width: 520, height: 480)
    private static let margin: CGFloat = 32
    /// The helper app's icon at the top.
    static let iconSide: CGFloat = 96
    private let model: ComputerUseStepModel
    private let context: OnboardingStepContext
    private let icon = NSImageView()
    private let body = OnboardingLabel.make(font: Typography.system(size: TypeScale.body), color: Palette.textSecondary, lines: 2)
    private let note = OnboardingLabel.make(font: Typography.system(size: TypeScale.caption), color: Palette.textSecondary, lines: 3)
    private var rows: [ComputerUsePermissionPane: ComputerUseGrantRow] = [:]
    private let icons = ComputerUseGrantIcon.Cache()
    private lazy var notNow = OnboardingControl.plainButton(OnboardingStrings.computerUseNotNow, target: self, action: #selector(notNowPressed))
    private lazy var done = OnboardingCapsuleButton(title: OnboardingStrings.done, style: .primary, target: self, action: #selector(donePressed))
    private lazy var restart = OnboardingCapsuleButton(title: OnboardingStrings.computerUseRestart, style: .primary,
                                                       target: self, action: #selector(restartPressed))
    private var panel: HelperDragPanel?
    private var panelPane: ComputerUsePermissionPane?
    private var seenComebacks: Int
    private var loop: ObservationLoop?

    init(model: ComputerUseStepModel, context: OnboardingStepContext) {
        self.model = model
        self.context = context
        seenComebacks = model.comebacks
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        // Closing the window stops the step (windowWillClose, OnboardingModel.leave) but does not move
        // this view out of it: the panel goes now, not on a later render this view may not live to run.
        model.onStop = { [weak self] in self?.hidePanel() }
        icon.imageScaling = .scaleProportionallyUpOrDown
        let heading = OnboardingLabel.make(OnboardingStrings.computerUseHeading,
                                           font: Typography.system(size: TypeScale.heading, weight: TypeScale.emphasis), lines: 2)
        for label in [heading, body] { label.alignment = .center }
        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = 12
        for pane in ComputerUsePermissionPane.allCases {
            let action = pane == .accessibility ? #selector(allowAccessibility) : #selector(allowScreenshots)
            let row = ComputerUseGrantRow(pane: pane, icons: icons, mainWork: context.mainWork, target: self, action: action)
            rows[pane] = row
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        notNow.setAccessibilityIdentifier("cmux.computerUse.notNow")
        done.setAccessibilityIdentifier("cmux.computerUse.done")
        let buttons = NSStackView(views: [notNow, restart, done])
        buttons.spacing = 8
        for view in [icon, heading, body, list, note, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let margin = Self.margin
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 36), icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSide), icon.heightAnchor.constraint(equalToConstant: Self.iconSide),
            heading.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            body.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            list.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 24),
            list.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            list.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            buttons.heightAnchor.constraint(equalToConstant: OnboardingCapsuleButton.height),
            note.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            note.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -16),
            note.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
        ])
        for label in [heading, body] {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            ])
        }
        // node-free: the onboarding tool window, in no tab
        loop = ObservationLoop(owner: "onboarding.computerUse", delivery: .visible(nil), on: context.mainWork) { [weak self] in
            self?.render()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    @objc private func allowAccessibility() { model.allow(.accessibility) }
    @objc private func allowScreenshots() { model.allow(.screenRecording) }
    @objc private func notNowPressed() { context.skip() }
    @objc private func donePressed() { context.next() }
    @objc private func restartPressed() { model.restart() }

    /// The row's trailing control for the current grants.
    static func control(_ pane: ComputerUsePermissionPane, _ model: ComputerUseStepModel) -> ComputerUseGrantRow.Control {
        let permissions = model.permissions
        if permissions.helperFailed || permissions.helperVersionMismatch { return .hidden }
        if permissions.granted(pane) { return .done }
        return .allow(primary: model.isPrimary(pane))
    }

    /// The footer's one line on why Allow cannot help, if it cannot.
    static func noteText(_ model: ComputerUseStepModel) -> String? {
        let permissions = model.permissions
        if permissions.helperFailed { return OnboardingStrings.computerUseHelperFailed }
        if permissions.helperVersionMismatch { return OnboardingStrings.computerUseHelperVersionMismatch }
        if model.unavailable { return OnboardingStrings.computerUseHelperUnavailable }
        if permissions.isOff { return OnboardingStrings.computerUseOff }
        return nil
    }

    private func render() {
        // The helper's icon, read off the main thread by the App once the helper is found; cmux's own until then
        // (a generic file icon says nothing).
        let shownIcon = model.helperAppIcon ?? NSApp.applicationIconImage
        if icon.image !== shownIcon { icon.image = shownIcon }
        for (pane, row) in rows { row.update(Self.control(pane, model)) }
        let allGranted = model.allGranted
        body.stringValue = allGranted ? OnboardingStrings.computerUseReady : OnboardingStrings.computerUseBody
        let text = Self.noteText(model)
        note.stringValue = text ?? ""
        note.isHidden = text == nil
        done.isHidden = !allGranted
        restart.isHidden = !model.permissions.helperFailed
        notNow.isHidden = allGranted || model.permissions.helperFailed
        if model.comebacks != seenComebacks {
            seenComebacks = model.comebacks
            bringForward()
        }
        renderPanel()
    }

    /// A grant landed while System Settings was in front: this window comes back.
    private func bringForward() {
        guard let window else { return }
        window.orderFrontRegardless()
        guard !WindowPlacement.noActivate else { return }
        NSApp.activate()
        window.makeKey()
    }

    private func renderPanel() {
        let helping = model.helping
        guard helping != panelPane else { return }
        panelPane = helping
        panel?.orderOut(nil)
        panel = nil
        guard let helping, window != nil, let url = model.helperAppURL else { return }
        let next = HelperDragPanel(appURL: url, icon: model.helperAppIcon, pane: helping, mainWork: context.mainWork,
                                   onBack: { [weak model] in model?.dismissHelper() },
                                   onDrop: { [weak model] in model?.helperDropped() })
        next.show(on: window?.screen)
        panel = next
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hidePanel()
        if window != nil { render() }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel = nil
        panelPane = nil
    }
}
