import AppKit

@MainActor
final class SimulatorLogTools: SimulatorToolSection, SimulatorToolsSection {
    private let coordinator: SimulatorPaneCoordinator
    private let bundleIdentifier = SimulatorClosureTextField()
    private let streamButton = SimulatorClosureButton()
    private let output = SimulatorClosureTextView(minimumHeight: 120)
    private var lastOutput = ""

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        super.init(simulatorStrings.logs)
        bundleIdentifier.placeholderString = String(localized: simulatorStrings.bundleIdentifier)
        add(bundleIdentifier)
        let recent = SimulatorClosureButton(title: String(localized: simulatorStrings.recentLogs)) {
            [weak self] in
            guard let self else { return }
            let bundle = bundleIdentifier.stringValue
            coordinator.scheduleControlAction("load-recent-logs") {
                await $0.loadRecentLogs(bundleIdentifier: bundle)
            }
        }
        streamButton.handler = { [weak self] in
            guard let self else { return }
            let bundle = bundleIdentifier.stringValue
            coordinator.scheduleControlAction("toggle-log-stream") {
                await $0.toggleLogStream(bundleIdentifier: bundle)
            }
        }
        add(simulatorRow([recent, streamButton]))
        output.textView.isEditable = false
        output.isHidden = true
        add(output)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update() {
        streamButton.title = String(localized: coordinator.isStreamingLogs
            ? simulatorStrings.stopLogStream
            : simulatorStrings.startLogStream)
        let text = coordinator.isStreamingLogs ? coordinator.liveLogsText : coordinator.recentLogsText
        if text != lastOutput {
            lastOutput = text
            output.string = text
        }
        output.isHidden = text.isEmpty
    }
}
