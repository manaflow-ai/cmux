import AppKit
import CmuxNextDesign

/// Computer use: one `PermissionRow` card per grant, then at most one short
/// note (Computer Use off, unavailable, version mismatch or a helper that
/// did not answer). Allow opens that list in System Settings and docks
/// `HelperDragPanel` under it (`HelperDragPanelDock`); the card turns
/// Allowed and the panel goes when the grant lands (`ComputerUseStepModel`).
final class ComputerUseStepView: NSView {
    private let model: ComputerUseStepModel
    private let locator: any SystemSettingsWindowLocating
    private(set) var rows: [ComputerUsePermissionPane: PermissionRow] = [:]
    /// The drag panel's dock while a grant is pending.
    private(set) var dock: HelperDragPanelDock?
    private var dockPane: ComputerUsePermissionPane?
    private var loop: RenderLoop?
    /// Shown after Allow when this build has no signed helper.
    let unavailableLabel = OnboardingLabel.make(OnboardingStrings.computerUseHelperUnavailable,
                                                font: OnboardingMetrics.captionFont,
                                                color: Palette.textSecondary, lines: 2)
    /// Shown while Computer Use is off: Allow turns it on.
    let offLabel = OnboardingLabel.make(OnboardingStrings.computerUseOff,
                                        font: OnboardingMetrics.captionFont,
                                        color: Palette.textSecondary, lines: 2)
    /// Shown while the helper does not speak this build's protocol.
    let mismatchLabel = OnboardingLabel.make(OnboardingStrings.computerUseHelperVersionMismatch,
                                             font: OnboardingMetrics.captionFont,
                                             color: Palette.textSecondary, lines: 2)

    let failedLabel = OnboardingLabel.make(OnboardingStrings.computerUseHelperFailed,
                                           font: OnboardingMetrics.captionFont,
                                           color: Palette.textSecondary, lines: 3)
    private(set) lazy var restartButton = OnboardingControl.button(OnboardingStrings.computerUseRestart,
                                                                    target: self, action: #selector(restartHelper))

    init(model: ComputerUseStepModel, locator: any SystemSettingsWindowLocating = SystemSettingsWindowLocator()) {
        self.model = model
        self.locator = locator
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for pane in ComputerUsePermissionPane.allCases {
            let action = pane == .accessibility ? #selector(allowAccessibility) : #selector(allowScreenRecording)
            let row = PermissionRow(symbol: Self.symbol(pane), title: OnboardingStrings.computerUseName(pane),
                                    detail: OnboardingStrings.computerUseDetail(pane), target: self, action: action)
            rows[pane] = row
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if let last = rows[.screenRecording] { stack.setCustomSpacing(12, after: last) }
        for label in [offLabel, unavailableLabel, mismatchLabel, failedLabel] {
            label.isHidden = true
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        restartButton.isHidden = true
        stack.addArrangedSubview(restartButton)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func symbol(_ pane: ComputerUsePermissionPane) -> String {
        switch pane {
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        }
    }

    @objc private func allowAccessibility() { model.allow(.accessibility) }
    @objc private func allowScreenRecording() { model.allow(.screenRecording) }

    @objc private func restartHelper() { model.restart() }

    /// Applies the model: each card's state, the note, and the drag panel.
    func render() {
        let failed = model.permissions.helperFailed
        for (pane, row) in rows {
            row.isHidden = failed
            row.update(state: model.cardState(pane))
        }
        failedLabel.isHidden = !failed
        restartButton.isHidden = !failed
        offLabel.isHidden = !model.permissions.isOff || model.unavailable
        unavailableLabel.isHidden = !model.unavailable
        mismatchLabel.isHidden = !model.permissions.helperVersionMismatch
        let helping = model.helping
        guard helping != dockPane else { return }
        dockPane = helping
        dock?.close()
        dock = nil
        guard helping != nil, let window, let url = model.helperAppURL else { return }
        let panel = HelperDragPanel(appURL: url) { [weak model] in model?.dismissHelper() }
        let next = HelperDragPanelDock(panel: panel, sheet: window, locator: locator)
        next.show()
        dock = next
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the step (or closing the window) takes the panel with it.
        // Back in a window (a gallery switch), a pending grant's panel returns.
        dock?.close()
        dock = nil
        dockPane = nil
        if window != nil { render() }
    }
}
