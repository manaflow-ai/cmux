import AppKit
import CmuxSimulator

@MainActor
final class SimulatorCaptureTools: SimulatorToolSection, SimulatorToolsSection {
    private let coordinator: SimulatorPaneCoordinator
    private let screenshotPicker = SimulatorClosurePopUpButton()
    private let videoPicker = SimulatorClosurePopUpButton()
    private let videoButton = SimulatorClosureButton()
    private let screenshotFormats = SimulatorScreenshotFormat.allCases
    private let videoCodecs = SimulatorVideoCodec.allCases

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        super.init(simulatorStrings.capture)
        screenshotPicker.addItems(withTitles: screenshotFormats.map { $0.rawValue.uppercased() })
        videoPicker.addItems(withTitles: videoCodecs.map { $0.rawValue.uppercased() })
        let screenshot = SimulatorClosureButton(title: String(localized: simulatorStrings.screenshot)) {
            [weak self] in self?.captureScreenshot()
        }
        videoButton.handler = { [weak self] in self?.toggleVideo() }
        add(simulatorRow([screenshotPicker, screenshot]))
        add(simulatorRow([videoPicker, videoButton]))
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update() {
        videoButton.title = String(localized: coordinator.isVideoRecording
            ? simulatorStrings.stopRecording
            : simulatorStrings.startRecording)
        videoButton.contentTintColor = coordinator.isVideoRecording ? .systemRed : .controlAccentColor
    }

    private func captureScreenshot() {
        guard screenshotFormats.indices.contains(screenshotPicker.indexOfSelectedItem) else { return }
        let format = screenshotFormats[screenshotPicker.indexOfSelectedItem]
        coordinator.scheduleControlAction("capture-screenshot") {
            await $0.captureScreenshot(format: format)
        }
    }

    private func toggleVideo() {
        guard videoCodecs.indices.contains(videoPicker.indexOfSelectedItem) else { return }
        let codec = videoCodecs[videoPicker.indexOfSelectedItem]
        coordinator.scheduleControlAction("toggle-video-recording") {
            await $0.toggleVideoRecording(codec: codec)
        }
    }
}
