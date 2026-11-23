public import AVFoundation
import Foundation

/// Where a recorded engine's microphone audio comes from
/// (``RecordedDictationTranscriber``). ``MicrophoneDictationCapture`` is the
/// device; tests feed scripted buffers.
public protocol DictationAudioCapturing: Sendable {
    /// Opens the input and hands every buffer to `onBuffer`, on the audio
    /// thread. `onFailure` reports a capture that broke after it started (a
    /// device that went away and could not be reopened).
    ///
    /// - Throws: ``DictationFailure/audioCaptureFailed(_:)`` when there is no
    ///   input to open.
    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onFailure: @escaping @Sendable (DictationFailure) async -> Void
    ) async throws

    /// Closes the input and releases the microphone. Safe to call at any
    /// time, more than once.
    func stop() async
}

/// The default input device through an `AVAudioEngine` input tap, the same
/// capture ``SFSpeechDictationTranscriber`` does, restarted when the device
/// or its format changes.
public actor MicrophoneDictationCapture: DictationAudioCapturing {
    private var audioEngine: AVAudioEngine?
    private var configurationChangeTask: Task<Void, Never>?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var onFailure: (@Sendable (DictationFailure) async -> Void)?

    public init() {}

    public func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onFailure: @escaping @Sendable (DictationFailure) async -> Void
    ) async throws {
        self.onBuffer = onBuffer
        self.onFailure = onFailure
        do {
            try startAudioEngine()
        } catch {
            self.onBuffer = nil
            self.onFailure = nil
            throw error as? DictationFailure ?? DictationFailure.audioCaptureFailed(error.localizedDescription)
        }
        observeConfigurationChanges()
    }

    public func stop() async {
        onBuffer = nil
        onFailure = nil
        stopAudioEngine()
    }

    private func startAudioEngine() throws {
        guard let sink = onBuffer else { return }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationFailure.audioCaptureFailed("no audio input device")
        }
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            sink(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
        audioEngine = engine
    }

    private func stopAudioEngine() {
        configurationChangeTask?.cancel()
        configurationChangeTask = nil
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
    }

    /// Restarts the tap when the input device or its format changes
    /// (device unplugged, default input switched) instead of crashing on a
    /// stale-format tap.
    private func observeConfigurationChanges() {
        // task-owner: stored in configurationChangeTask; stop() cancels it
        configurationChangeTask = Task { [weak self] in
            let changes = NotificationCenter.default.notifications(
                named: .AVAudioEngineConfigurationChange
            )
            for await _ in changes {
                guard let self else { return }
                await self.handleConfigurationChange()
            }
        }
    }

    private func handleConfigurationChange() async {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        do {
            try startAudioEngine()
        } catch {
            let report = onFailure
            stopAudioEngine()
            await report?(.audioCaptureFailed(error.localizedDescription))
        }
    }
}
