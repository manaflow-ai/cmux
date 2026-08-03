import AppKit

@MainActor
final class SimulatorToolsPanel: NSScrollView {
    private let coordinator: SimulatorPaneCoordinator
    private let content = SimulatorFlippedView()
    private let stack = NSStackView()
    private let progressRow = NSStackView()
    private let progress = NSProgressIndicator()
    private let progressLabel = simulatorLabel("", color: .secondaryLabelColor)
    private let failureLabel = simulatorLabel("", color: .systemOrange)
    private let failureDetails = simulatorLabel(
        "",
        font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular),
        color: .secondaryLabelColor
    )
    private let sections: [SimulatorToolSection]

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        sections = [
            SimulatorDeviceTools(coordinator: coordinator),
            SimulatorTextInputTools(coordinator: coordinator),
            SimulatorApplicationTools(coordinator: coordinator),
            SimulatorURLMediaClipboardTools(coordinator: coordinator),
            SimulatorLocationTools(coordinator: coordinator),
            SimulatorNotificationPrivacyTools(coordinator: coordinator),
            SimulatorAppearanceTools(coordinator: coordinator),
            SimulatorCaptureTools(coordinator: coordinator),
            SimulatorLogTools(coordinator: coordinator),
            SimulatorCameraTools(coordinator: coordinator),
            SimulatorInspectionTools(coordinator: coordinator),
            SimulatorWebInspectorTools(coordinator: coordinator),
            SimulatorActivityTools(coordinator: coordinator),
        ]
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        drawsBackground = true
        borderType = .noBorder

        content.translatesAutoresizingMaskIntoConstraints = false
        documentView = content
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        progress.style = .spinning
        progress.controlSize = .mini
        progressLabel.stringValue = String(localized: simulatorStrings.loading)
        progressRow.orientation = .horizontal
        progressRow.alignment = .centerY
        progressRow.spacing = 6
        progressRow.addArrangedSubview(progress)
        progressRow.addArrangedSubview(progressLabel)
        stack.addArrangedSubview(progressRow)
        stack.addArrangedSubview(failureLabel)
        stack.addArrangedSubview(failureDetails)
        for section in sections {
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        update(backgroundColor: .windowBackgroundColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(backgroundColor: NSColor) {
        self.backgroundColor = backgroundColor
        progressRow.isHidden = !coordinator.isPerformingControlAction
        if coordinator.isPerformingControlAction {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
        if let failure = coordinator.controlFailure {
            failureLabel.isHidden = false
            failureDetails.isHidden = false
            failureLabel.stringValue = String(localized: simulatorStrings.failure(failure.code))
            failureDetails.stringValue = "\(String(localized: simulatorStrings.technicalDetails)): \(failure.code)"
        } else {
            failureLabel.isHidden = true
            failureDetails.isHidden = true
        }
        for case let section as SimulatorToolsSection in sections {
            section.update()
        }
    }
}

@MainActor
private final class SimulatorFlippedView: NSView {
    override var isFlipped: Bool { true }
}
