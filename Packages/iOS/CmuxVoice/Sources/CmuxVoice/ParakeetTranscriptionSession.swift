@preconcurrency public import AVFoundation
import FluidAudio
public import Foundation

/// A ``VoiceTranscriptionSession`` backed by FluidAudio's Parakeet sliding-window ASR.
public final class ParakeetTranscriptionSession: VoiceTranscriptionSession {
    private let manager: SlidingWindowAsrManager
    private let continuation: AsyncStream<VoiceTranscriptionUpdate>.Continuation
    private let stream: AsyncStream<VoiceTranscriptionUpdate>
    private let audioContinuation: AsyncStream<AudioBufferBox>.Continuation
    private let startupTask: Task<Void, Never>
    private let updateTask: Task<Void, Never>
    private let audioTask: Task<Void, Never>
    private var isFinished = false

    /// Creates and starts a Parakeet transcription session.
    /// - Parameter modelDirectory: The directory containing the downloaded Parakeet model.
    public init(modelDirectory: URL) {
        let manager = SlidingWindowAsrManager()
        self.manager = manager
        let (stream, continuation) = AsyncStream<VoiceTranscriptionUpdate>.makeStream()
        let (audioStream, audioContinuation) = AsyncStream<AudioBufferBox>.makeStream()
        self.stream = stream
        self.continuation = continuation
        self.audioContinuation = audioContinuation
        self.startupTask = Task {
            do {
                let models = try await AsrModels.downloadAndLoad(
                    to: modelDirectory,
                    version: .v3,
                    encoderPrecision: .int8
                )
                try await manager.loadModels(models)
                try await manager.startStreaming(source: .microphone)
            } catch {
                continuation.yield(.failed(error.localizedDescription))
                continuation.finish()
            }
        }
        self.updateTask = Self.makeUpdateTask(manager: manager, continuation: continuation)
        self.audioTask = Self.makeAudioTask(manager: manager, audioStream: audioStream)
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
        Task { [manager, continuation, updateTask, audioTask] in
            await audioTask.value
            do {
                let final = try await manager.finish()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !final.isEmpty {
                    continuation.yield(.final(final))
                }
            } catch {
                continuation.yield(.failed(error.localizedDescription))
            }
            await manager.cancel()
            updateTask.cancel()
            continuation.finish()
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
        audioStream: AsyncStream<AudioBufferBox>
    ) -> Task<Void, Never> {
        Task {
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
