public import CmuxNextCompat
public import CmuxNextTrace

/// The app's ring through its black box's ``TraceRuntime``: the black box maps the recording ring on the
/// `.files` lane of `work`, then a start or a stop only swaps the ring's writers (no disk I/O).
public struct RuntimeTraceRecording: TraceAppRecording {
    private let blackBox: TraceBlackBox?
    private let work: any MayBlockRunner

    /// - Parameters:
    ///   - blackBox: The process's black box; nil when this launch records none (then there is no recording
    ///     ring and every start reports it).
    ///   - work: The blocking-work lanes the mapping runs on.
    public init(blackBox: TraceBlackBox?, work: any MayBlockRunner) {
        self.blackBox = blackBox
        self.work = work
    }

    public func prepare() async -> Bool {
        guard let blackBox else { return false }
        return (try? await work.runFiles(.userVisible) { blackBox.prepareRecording() }) ?? false
    }

    public func start(_ request: TraceRuntime.RecordingRequest) -> TraceRuntime.RecordingStatus {
        blackBox?.runtime.startRecording(request) ?? .idle
    }

    public func stop() -> TraceRuntime.RecordingStatus {
        blackBox?.runtime.stopRecording() ?? .idle
    }

    public var status: TraceRuntime.RecordingStatus { blackBox?.runtime.recordingStatus ?? .idle }
}
