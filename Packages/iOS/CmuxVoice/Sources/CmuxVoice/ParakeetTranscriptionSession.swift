@preconcurrency public import AVFoundation
import CmuxMobileSupport
import FluidAudio
public import Foundation
import OSLog

private let parakeetSessionLog = Logger(subsystem: "dev.cmux.ios", category: "parakeet-session")

/// A ``VoiceTranscriptionSession`` backed by FluidAudio's Parakeet sliding-window ASR.
public final class ParakeetTranscriptionSession: VoiceTranscriptionSession {
    private let cancelManager: @Sendable () async -> Void
    private let finishTranscript: @Sendable () async throws -> String
    private let continuation: AsyncStream<VoiceTranscriptionUpdate>.Continuation
    private let stream: AsyncStream<VoiceTranscriptionUpdate>
    private let audioContinuation: AsyncStream<AudioBufferBox>.Continuation
    /// Loads the CoreML models and starts streaming; resolves `true` only when
    /// the ASR pipeline actually came up, so ``finish()`` knows whether there is
    /// anything to finalize.
    private let startupTask: Task<Bool, Never>
    private let updateTask: Task<Void, Never>
    private let audioTask: Task<Void, Never>
    private let startupDeadline: Duration
    private let sleepForStartupDeadline: @Sendable (Duration) async throws -> Void
    private var isFinished = false

    /// Upper bound on tap buffers queued between the audio tap and the ASR
    /// actor; see the `makeStream` comment in `init` for the sizing rationale.
    private static let maxBufferedAudioChunks = 1024

    /// Creates and starts a Parakeet transcription session.
    /// - Parameter modelDirectory: The directory containing the downloaded Parakeet model.
    public convenience init(modelDirectory: URL) {
        let manager = SlidingWindowAsrManager()
        self.init(
            startup: {
                let models = try await AsrModels.downloadAndLoad(
                    to: modelDirectory,
                    version: .v3,
                    encoderPrecision: .int8
                )
                try await manager.loadModels(models)
                try await manager.startStreaming(source: .microphone)
                return true
            },
            transcriptionUpdates: AsyncStream<ParakeetStreamingUpdate> { continuation in
                let task = Task {
                    for await update in await manager.transcriptionUpdates {
                        continuation.yield(ParakeetStreamingUpdate(text: update.text, isConfirmed: update.isConfirmed))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            },
            streamAudioToManager: { box in
                await manager.streamAudio(box.buffer)
            },
            finishTranscript: {
                try await manager.finish()
            },
            cancelManager: {
                await manager.cancel()
            }
        )
    }

    init(
        startupDeadline: Duration = .seconds(10),
        sleepForStartupDeadline: @escaping @Sendable (Duration) async throws -> Void = {
            // Intended bounded deadline; the sleeper is injected so tests never
            // rely on real time.
            try await ContinuousClock().sleep(for: $0)
        },
        startup: @escaping @Sendable () async throws -> Bool,
        transcriptionUpdates: AsyncStream<ParakeetStreamingUpdate>,
        streamAudioToManager: @escaping @Sendable (AudioBufferBox) async -> Void,
        finishTranscript: @escaping @Sendable () async throws -> String,
        cancelManager: @escaping @Sendable () async -> Void
    ) {
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
        self.startupDeadline = startupDeadline
        self.sleepForStartupDeadline = sleepForStartupDeadline
        self.finishTranscript = finishTranscript
        self.cancelManager = cancelManager
        let startupTask = Task {
            do {
                return try await startup()
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
        self.updateTask = Self.makeUpdateTask(updates: transcriptionUpdates, continuation: continuation)
        self.audioTask = Self.makeAudioTask(
            audioStream: audioStream,
            startupTask: startupTask,
            streamAudioToManager: streamAudioToManager
        )
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
        let job = FinishAfterStartupJob(
            continuation: continuation,
            updateTask: updateTask,
            audioTask: audioTask,
            startupTask: startupTask,
            startupDeadline: startupDeadline,
            sleepForStartupDeadline: sleepForStartupDeadline,
            finishTranscript: finishTranscript,
            cancelManager: cancelManager
        )
        Task {
            await job.run()
        }
    }

    /// Cancels recognition and closes the update stream.
    public func cancel() {
        isFinished = true
        startupTask.cancel()
        audioContinuation.finish()
        audioTask.cancel()
        updateTask.cancel()
        Task { [cancelManager, continuation] in
            await cancelManager()
            continuation.finish()
        }
    }

    private static func joinedTranscript(_ leading: String, _ trailing: String) -> String {
        if leading.isEmpty { return trailing }
        if trailing.isEmpty { return leading }
        return "\(leading) \(trailing)"
    }

    private static func forwardUpdates(
        from updates: AsyncStream<ParakeetStreamingUpdate>,
        to continuation: AsyncStream<VoiceTranscriptionUpdate>.Continuation
    ) async {
        var confirmedText = ""
        var volatileText = ""
        var volatileIsConfirmed = false
        for await update in updates {
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
        updates: AsyncStream<ParakeetStreamingUpdate>,
        continuation: AsyncStream<VoiceTranscriptionUpdate>.Continuation
    ) -> Task<Void, Never> {
        Task {
            await forwardUpdates(from: updates, to: continuation)
        }
    }

    private static func makeAudioTask(
        audioStream: AsyncStream<AudioBufferBox>,
        startupTask: Task<Bool, Never>,
        streamAudioToManager: @escaping @Sendable (AudioBufferBox) async -> Void
    ) -> Task<Void, Never> {
        Task {
            // Hold audio in this session's BOUNDED stream until the ASR pipeline
            // is actually up: the manager's own input stream is unbounded, so
            // forwarding during a multi-second CoreML load would just move the
            // unbounded backlog into FluidAudio.
            guard await startupTask.value else { return }
            for await box in audioStream {
                guard !Task.isCancelled else { break }
                await streamAudioToManager(box)
            }
        }
    }

    private static func waitForStartup(
        _ startupTask: Task<Bool, Never>,
        deadline: Duration,
        sleepForDeadline: @escaping @Sendable (Duration) async throws -> Void
    ) async -> StartupWaitResult {
        let (stream, continuation) = AsyncStream<StartupWaitResult>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let startupWaiter = Task {
            continuation.yield(.completed(await startupTask.value))
        }
        let timeoutWaiter = Task {
            do {
                try await sleepForDeadline(deadline)
                continuation.yield(.timedOut)
            } catch is CancellationError {
                return
            } catch {
                continuation.yield(.timedOut)
            }
        }
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next() ?? .timedOut
        if case .timedOut = result {
            startupTask.cancel()
        }
        startupWaiter.cancel()
        timeoutWaiter.cancel()
        continuation.finish()
        return result
    }

    fileprivate static func finishAfterStartup(
        continuation: AsyncStream<VoiceTranscriptionUpdate>.Continuation,
        updateTask: Task<Void, Never>,
        audioTask: Task<Void, Never>,
        startupTask: Task<Bool, Never>,
        startupDeadline: Duration,
        sleepForStartupDeadline: @escaping @Sendable (Duration) async throws -> Void,
        finishTranscript: @escaping @Sendable () async throws -> String,
        cancelManager: @escaping @Sendable () async -> Void
    ) async {
        let startupResult = await waitForStartup(
            startupTask,
            deadline: startupDeadline,
            sleepForDeadline: sleepForStartupDeadline
        )
        guard case .completed(let started) = startupResult else {
            startupTask.cancel()
            audioTask.cancel()
            updateTask.cancel()
            await cancelManager()
            continuation.yield(.failed(L10n.string(
                "mobile.voice.transcription.startupTimedOut",
                defaultValue: "Voice transcription is still loading. Try again in a moment."
            )))
            continuation.finish()
            return
        }
        await audioTask.value
        defer {
            updateTask.cancel()
            continuation.finish()
        }
        guard started else {
            // The pipeline never came up (early stop or startup failure already
            // reported); there is no transcript to finalize.
            await cancelManager()
            return
        }
        do {
            let final = try await finishTranscript()
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
        await cancelManager()
    }
}

private struct FinishAfterStartupJob: Sendable {
    let continuation: AsyncStream<VoiceTranscriptionUpdate>.Continuation
    let updateTask: Task<Void, Never>
    let audioTask: Task<Void, Never>
    let startupTask: Task<Bool, Never>
    let startupDeadline: Duration
    let sleepForStartupDeadline: @Sendable (Duration) async throws -> Void
    let finishTranscript: @Sendable () async throws -> String
    let cancelManager: @Sendable () async -> Void

    func run() async {
        await ParakeetTranscriptionSession.finishAfterStartup(
            continuation: continuation,
            updateTask: updateTask,
            audioTask: audioTask,
            startupTask: startupTask,
            startupDeadline: startupDeadline,
            sleepForStartupDeadline: sleepForStartupDeadline,
            finishTranscript: finishTranscript,
            cancelManager: cancelManager
        )
    }
}

struct ParakeetStreamingUpdate: Sendable {
    let text: String
    let isConfirmed: Bool
}

private enum StartupWaitResult: Sendable {
    case completed(Bool)
    case timedOut
}

// AVAudioPCMBuffer is handed off from AVAudioEngine's tap thread and consumed
// serially by this session's single audio task; the buffer is never shared after yield.
struct AudioBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
