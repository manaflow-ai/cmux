import AVFoundation
import CmuxNextCompat
import Foundation

/// The default input device through an `AVAudioEngine` input tap, reopened when the device or
/// its format changes (device unplugged, default input switched) instead of crashing on a
/// stale-format tap. The one capture for the engines that open the microphone themselves
/// (``SFSpeechDictationTranscriber``, ``MicrophoneDictationCapture``).
///
/// Its calls are synchronous, so an actor's teardown needs no suspension. The mutex guards the
/// engine between its owner and the change observer; its sections are short and never wait.
final class DictationInputTap: Sendable {
    typealias Sink = @Sendable (AVAudioPCMBuffer) -> Void
    typealias Report = @Sendable (DictationFailure) async -> Void

    private struct State {
        var engine: AVAudioEngine?
        var sink: Sink?
        var report: Report?
        var changes: Task<Void, Never>?
    }

    private let state = Mutex<State>(State())

    /// Opens the input: every buffer goes to `onBuffer`, on the audio thread. `onFailure`
    /// reports an input that went away and could not be reopened; the tap is closed by then.
    ///
    /// - Throws: ``DictationFailure/audioCaptureFailed(_:)`` when there is no input to open, or
    ///   the engine's own error when it does not start.
    func start(onBuffer: @escaping Sink, onFailure: @escaping Report) throws {
        try state.withLock { state in
            Self.close(&state)
            state.sink = onBuffer
            state.report = onFailure
            do {
                try Self.open(&state)
            } catch {
                Self.close(&state)
                throw error
            }
            // task-owner: stored in the state's `changes`; close cancels it
            state.changes = Task { [weak self] in
                let notifications = NotificationCenter.default.notifications(
                    named: .AVAudioEngineConfigurationChange
                )
                for await _ in notifications {
                    guard let self else { return }
                    guard let lost = self.reopen() else { continue }
                    await lost.report(lost.failure)
                    return
                }
            }
        }
    }

    /// Closes the input and releases the microphone. Safe at any time, more than once.
    func stop() {
        state.withLock { state in Self.close(&state) }
    }

    /// Reopens the input after a change. Nil when it reopened, or was closed already; else the
    /// failure and who hears it, with the tap closed.
    private func reopen() -> (report: Report, failure: DictationFailure)? {
        state.withLock { state in
            guard let engine = state.engine else { return nil }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            state.engine = nil
            do {
                try Self.open(&state)
                return nil
            } catch {
                let report = state.report
                Self.close(&state)
                guard let report else { return nil }
                return (report, error as? DictationFailure ?? .audioCaptureFailed(error.localizedDescription))
            }
        }
    }

    private static func open(_ state: inout State) throws {
        guard let sink = state.sink else { return }
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
        state.engine = engine
    }

    private static func close(_ state: inout State) {
        state.changes?.cancel()
        state.changes = nil
        state.sink = nil
        state.report = nil
        guard let engine = state.engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state.engine = nil
    }
}
