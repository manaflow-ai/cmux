import CmuxSimulator

@MainActor
final class AttachmentReadinessRecorder {
    var events: [SimulatorWorkerOutbound] = []
}
