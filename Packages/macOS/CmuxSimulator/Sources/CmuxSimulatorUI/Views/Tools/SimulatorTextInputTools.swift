import AppKit

@MainActor
final class SimulatorTextInputTools: SimulatorToolSection, SimulatorToolsSection {
    private let coordinator: SimulatorPaneCoordinator
    private let editor = SimulatorClosureTextView()
    private let typeButton = SimulatorClosureButton()
    private let progress = NSProgressIndicator()
    private let progressLabel = simulatorLabel("", color: .secondaryLabelColor)
    private var isTyping = false

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        super.init(simulatorStrings.textInput)
        editor.textView.setAccessibilityLabel(String(localized: simulatorStrings.textInputPlaceholder))
        editor.onChange = { [weak self] _ in self?.update() }
        add(editor)
        typeButton.title = String(localized: simulatorStrings.typeText)
        typeButton.handler = { [weak self] in self?.submit() }
        progress.style = .spinning
        progress.controlSize = .mini
        progressLabel.stringValue = String(localized: simulatorStrings.loading)
        add(simulatorRow([typeButton, progress, progressLabel]))
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update() {
        typeButton.isEnabled = !editor.string.isEmpty
            && !isTyping
            && coordinator.capabilities.contains(.keyboard)
        progress.isHidden = !isTyping
        progressLabel.isHidden = !isTyping
        isTyping ? progress.startAnimation(nil) : progress.stopAnimation(nil)
    }

    private func submit() {
        isTyping = true
        update()
        if case .failure = coordinator.beginTypeText(editor.string, completion: { [weak self] succeeded in
            guard let self else { return }
            isTyping = false
            if succeeded { editor.string = "" }
            update()
        }) {
            isTyping = false
            update()
        }
    }
}
