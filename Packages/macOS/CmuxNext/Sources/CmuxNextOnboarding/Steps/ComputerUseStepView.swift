import AppKit
import CmuxNextDesign

/// Computer use: one `PermissionRow` per grant. Allow opens that list in
/// System Settings and floats `HelperDragPanel` over it; the row turns Done
/// and the panel goes when the grant lands (`ComputerUseStepModel`).
final class ComputerUseStepView: NSView {
    private let model: ComputerUseStepModel
    private var rows: [ComputerUsePermissionPane: PermissionRow] = [:]
    private var panel: HelperDragPanel?
    private var panelPane: ComputerUsePermissionPane?
    private var loop: RenderLoop?

    init(model: ComputerUseStepModel) {
        self.model = model
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

    private func render() {
        for (pane, row) in rows { row.update(granted: model.permissions.granted(pane)) }
        let helping = model.helping
        guard helping != panelPane else { return }
        panelPane = helping
        panel?.orderOut(nil)
        panel = nil
        guard helping != nil, let url = model.helperAppURL else { return }
        let next = HelperDragPanel(appURL: url) { [weak model] in model?.dismissHelper() }
        next.show(on: window?.screen)
        panel = next
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the step (or closing onboarding) takes the panel with it.
        // Back in a window (a gallery switch), a pending grant's panel returns.
        panel?.orderOut(nil)
        panel = nil
        panelPane = nil
        if window != nil { render() }
    }
}
