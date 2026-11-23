import AVFoundation
import Foundation
import os

/// The default input device through an `AVAudioEngine` input tap, reopened when the device or
/// its format changes (device unplugged, default input switched) instead of crashing on a
/// stale-format tap. The one capture for the engines that open the microphone themselves
/// (``SFSpeechDictationTranscriber``, ``MicrophoneDictationCapture``).
///
/// Its calls are synchronous, so an actor's teardown needs no suspension. The lock guards the
/// engine between its owner and the change observer; its sections are short and never wait.
final class DictationInputTap: @unchecked Sendable {
    typealias Sink = @Sendable (AVAudioPCMBuffer) -> Void
    typealias Report = @Sendable (DictationFailure) async -> Void

    private let lock = OSAllocatedUnfairLock()
    // Guarded by `lock`.
    private var engine: AVAudioEngine?
    private var sink: Sink?
    private var report: Report?
    private var changes: Task<Void, Never>?

    /// Opens the input: every buffer goes to `onBuffer`, on the audio thread. `onFailure`
    /// reports an input that went away and could not be reopened; the tap is closed by then.
    ///
    /// - Throws: ``DictationFailure/audioCaptureFailed(_:)`` when there is no input to open, or
    ///   the engine's own error when it does not start.
    func start(onBuffer: @escaping Sink, onFailure: @escaping Report) throws {
        lock.lock()
        defer { lock.unlock() }
        sink = onBuffer
        report = onFailure
        do {
            try open()
        } catch {
            close()
            throw error
        }
        observeConfigurationChanges()
    }

    /// Closes the input and releases the microphone. Safe at any time, more than once.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        close()
    }

    /// Call with `lock` held.
    private func open() throws {
        guard let sink else { return }
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
        self.engine = engine
    }

    /// Call with `lock` held.
    private func close() {
        changes?.cancel()
        changes = nil
        sink = nil
        report = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Call with `lock` held.
    private func observeConfigurationChanges() {
        // task-owner: stored in `changes`; close() cancels it
        changes = Task { [weak self] in
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

    /// Reopens the input after a change. Nil when it reopened, or was closed already; else the
    /// failure and who hears it, with the tap closed.
    private func reopen() -> (report: Report, failure: DictationFailure)? {
        lock.lock()
        defer { lock.unlock() }
        guard let engine else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        do {
            try open()
            return nil
        } catch {
            let report = report
            close()
            guard let report else { return nil }
            return (report, error as? DictationFailure ?? .audioCaptureFailed(error.localizedDescription))
        }
    }
}
