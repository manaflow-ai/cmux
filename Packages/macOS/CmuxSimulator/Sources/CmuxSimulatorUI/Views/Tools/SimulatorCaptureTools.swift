import CmuxSimulator
import SwiftUI

struct SimulatorCaptureTools: View {
    let coordinator: SimulatorPaneCoordinator
    @State private var screenshotFormat: SimulatorScreenshotFormat = .png
    @State private var videoCodec: SimulatorVideoCodec = .h264

    var body: some View {
        SimulatorToolSection(simulatorStrings.capture) {
            HStack {
                Picker(simulatorStrings.screenshot, selection: $screenshotFormat) {
                    ForEach(SimulatorScreenshotFormat.allCases, id: \.rawValue) { format in
                        Text(verbatim: format.rawValue.uppercased()).tag(format)
                    }
                }
                Button(simulatorStrings.screenshot) {
                    coordinator.scheduleControlAction("capture-screenshot") {
                        await $0.captureScreenshot(format: screenshotFormat)
                    }
                }
            }
            HStack {
                Picker(simulatorStrings.startRecording, selection: $videoCodec) {
                    ForEach(SimulatorVideoCodec.allCases, id: \.rawValue) { codec in
                        Text(verbatim: codec.rawValue.uppercased()).tag(codec)
                    }
                }
                Button(coordinator.isVideoRecording ? simulatorStrings.stopRecording : simulatorStrings.startRecording) {
                    coordinator.scheduleControlAction("toggle-video-recording") {
                        await $0.toggleVideoRecording(codec: videoCodec)
                    }
                }
                .tint(coordinator.isVideoRecording ? Color.red : Color.accentColor)
            }
        }
    }
}
