@preconcurrency public import AVFoundation
import CmuxMobileSupport
import FluidAudio
public import Foundation
import OSLog

private let parakeetSessionLog = Logger(subsystem: "dev.cmux.ios", category: "parakeet-session")

/// A ``VoiceTranscriptionSession`` backed by FluidAudio's Parakeet sliding-window ASR.
public final class ParakeetTranscriptionSession: VoiceTranscriptionSession {
    private let manager: SlidingWindowAsrManager
    private let continuation: AsyncStream<VoiceTranscriptionUpdate>.Continuation
    private let stream: AsyncStream<VoiceTranscriptionUpdate>
    private let audioContinuation: AsyncStream<AudioBufferBox>.Continuation
    /// Loads the CoreML models and starts streaming; resolves `true` only when
    /// the ASR pipeline actually came up, so ``finish()`` knows whether there is
    /// anything to finalize.
    private let startupTask: Task<Bool, Never>
    private let updateTask: Task<Void, Never>
    private let audioTask: Task<Void, Never>
    private var isFinished = false

    /// Upper bound on tap buffers queued between the audio tap and the ASR
    /// actor; see the `makeStream` comment in `init` for the sizing rationale.
    private static let maxBufferedAudioChunks = 1024

    /// Creates and starts a Parakeet transcription session.
    /// - Parameter modelDirectory: The directory containing the downloaded Parakeet model.
    public init(modelDirectory: URL) {
        let manager = SlidingWindowAsrManager()
        self.manager = manager
        let (stream, continuation) = AsyncStream<VoiceTranscriptionUpdate>.makeStream()
        // The mic tap produces buffers in realtime while `audioTask` awaits the
        // ASR actor, which stalls for seconds during first-load CoreML compilation
        // and can run slower than realtime on older hardware. An unbounded buffer
        // would retain every stalled AVAudioPCMBuffer and grow memory for as long
        // as the user keeps talking, so bound the backlog (1024 tap buffers is
        // ~20-100s of audio depending on the tap's delivered buffer size) and drop
        // the oldest audio instead: a clipped transcript beats an OOM kill.
        let (audioStream, audioContinuation) = AsyncStream<AudioBufferBox>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.maxBufferedAudioChunks)
        )
        self.stream = stream
        self.continuation = continuation
        self.audioContinuation = audioContinuation
        let startupTask = Task {
            do {
                let models = try await AsrModels.downloadAndLoad(
                    to: modelDirectory,
                    version: .v3,
                    encoderPrecision: .int8
                )
                try await manager.loadModels(models)
                try await manager.startStreaming(source: .microphone)
                return true
            } catch is CancellationError {
                // finish()/cancel() tore the session down before the model came
                // up; the teardown path owns cleanup, nothing to report.
                return false
            } catch {
                parakeetSessionLog.error("Parakeet startup failed: \(error.localizedDescription, privacy: .public)")
                continuation.yield(.failed(L10n.string(
                    "mobile.voice.transcription.startFailed",
                    defaultValue: "Couldn't start voice transcription. Try again."
                )))
                continuation.finish()
                return false
            }
        }
        self.startupTask = startupTask
        self.updateTask = Self.makeUpdateTask(manager: manager, continuation: continuation)
        self.audioTask = Self.makeAudioTask(manager: manager, audioStream: audioStream, startupTask: startupTask)
    }

    /// Incremental recognition updates.
    public var updates: AsyncStream<VoiceTranscriptionUpdate> { stream }

    /// Feeds a captured audio buffer into FluidAudio.
    /// - Parameter buffer: The captured audio buffer.
    public func streamAudio(_ buffer: AVAudioPCMBuffer) {
        audioContinuation.yield(AudioBufferBox(buffer: buffer))
    }

    /// Finishes the session and emits the final transcript.
    public func finish() {
        guard !isFinished else { return }
        isFinished = true
        audioContinuation.finish()
        // Stop a still-loading model: without this, a startup task that is in
        // `downloadAndLoad`/`loadModels` when the user stops early would later
        // call `startStreaming` on the manager this cleanup already finished,
        // resurrecting the CoreML session or racing the next mic session.
        startupTask.cancel()
        Task { [manager, continuation, updateTask, audioTask, startupTask] in
            let started = await startupTask.value
            await audioTask.value
            defer {
                updateTask.cancel()
                continuation.finish()
            }
            guard started else {
                // The pipeline never came up (early stop or startup failure
                // already reported); there is no transcript to finalize.
                await manager.cancel()
                return
            }
            do {
                let final = try await manager.finish()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !final.isEmpty {
                    continuation.yield(.final(final))
                }
            } catch {
                parakeetSessionLog.error("Parakeet finalize failed: \(error.localizedDescription, privacy: .public)")
                continuation.yield(.failed(L10n.string(
                    "mobile.voice.transcription.finishFailed",
                    defaultValue: "Transcription didn't finish. Try again."
                )))
            }
            await manager.cancel()
        }
    }

    /// Cancels recognition and closes the update stream.
    public func cancel() {
        isFinished = true
        startupTask.cancel()
        audioContinuation.finish()
        audioTask.cancel()
        updateTask.cancel()
        Task { [manager, continuation] in
            await manager.cancel()
            continuation.finish()
        }
    }

    private static func joinedTranscript(_ leading: String, _ trailing: String) -> String {
        if leading.isEmpty { return trailing }
        if trailing.isEmpty { return leading }
        return "\(leading) \(trailing)"
    }

    private static func forwardUpdates(
        from manager: SlidingWindowAsrManager,
        to continuation: AsyncStream<VoiceTranscriptionUpdate>.Continuation
    ) async {
        var confirmedText = ""
        var volatileText = ""
        var volatileIsConfirmed = false
        for await update in await manager.transcriptionUpdates {
            let trimmed = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if update.isConfirmed {
                if !volatileText.isEmpty, volatileText != trimmed {
                    confirmedText = joinedTranscript(confirmedText, volatileText)
                }
                volatileText = trimmed
                volatileIsConfirmed = true
            } else {
                if volatileIsConfirmed, !volatileText.isEmpty, volatileText != trimmed {
                    confirmedText = joinedTranscript(confirmedText, volatileText)
                }
                volatileText = trimmed
                volatileIsConfirmed = false
            }
            let partial = joinedTranscript(confirmedText, volatileText)
            if !partial.isEmpty {
                continuation.yield(.partial(partial))
            }
        }
    }

    private static func makeUpdateTask(
        manager: SlidingWindowAsrManager,
        continuation: AsyncStream<VoiceTranscriptionUpdate>.Continuation
    ) -> Task<Void, Never> {
        Task {
            await forwardUpdates(from: manager, to: continuation)
        }
    }

    private static func makeAudioTask(
        manager: SlidingWindowAsrManager,
        audioStream: AsyncStream<AudioBufferBox>,
        startupTask: Task<Bool, Never>
    ) -> Task<Void, Never> {
        Task {
            // Hold audio in this session's BOUNDED stream until the ASR pipeline
            // is actually up: the manager's own input stream is unbounded, so
            // forwarding during a multi-second CoreML load would just move the
            // unbounded backlog into FluidAudio.
            guard await startupTask.value else { return }
            for await box in audioStream {
                guard !Task.isCancelled else { break }
                await manager.streamAudio(box.buffer)
            }
        }
    }
}

// AVAudioPCMBuffer is handed off from AVAudioEngine's tap thread and consumed
// serially by this session's single audio task; the buffer is never shared after yield.
private struct AudioBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
