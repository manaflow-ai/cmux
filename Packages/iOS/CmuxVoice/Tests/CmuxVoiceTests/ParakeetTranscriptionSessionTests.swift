import Foundation
import Testing
@testable import CmuxVoice

@Suite struct ParakeetTranscriptionSessionTests {
    @Test func finishWaitsForStartupThenYieldsFinalTranscript() async {
        let startupGate = AsyncGate()
        let timeoutGate = AsyncGate()
        let session = ParakeetTranscriptionSession(
            sleepForStartupDeadline: { _ in
                try await timeoutGate.waitUntilOpened()
            },
            startup: {
                try await startupGate.waitUntilOpened()
                return true
            },
            transcriptionUpdates: Self.emptyStreamingUpdates(),
            streamAudioToManager: { _ in },
            finishTranscript: { "hello from parakeet" },
            cancelManager: {}
        )

        let updatesStream = session.updates
        let updatesTask = Task {
            var updates: [VoiceTranscriptionUpdate] = []
            for await update in updatesStream {
                updates.append(update)
            }
            return updates
        }

        session.finish()
        await startupGate.open()

        let updates = await updatesTask.value
        #expect(updates == [.final("hello from parakeet")])
    }

    @Test func finishReportsFailureWhenStartupDeadlineExpires() async {
        let startupGate = AsyncGate()
        let timeoutGate = AsyncGate()
        let session = ParakeetTranscriptionSession(
            sleepForStartupDeadline: { _ in
                try await timeoutGate.waitUntilOpened()
            },
            startup: {
                try await startupGate.waitUntilOpened()
                return true
            },
            transcriptionUpdates: Self.emptyStreamingUpdates(),
            streamAudioToManager: { _ in },
            finishTranscript: { "should not finish" },
            cancelManager: {}
        )

        let updatesStream = session.updates
        let updatesTask = Task {
            var updates: [VoiceTranscriptionUpdate] = []
            for await update in updatesStream {
                updates.append(update)
            }
            return updates
        }

        session.finish()
        await timeoutGate.open()

        let updates = await updatesTask.value
        #expect(updates == [
            .failed("Voice transcription is still loading. Try again in a moment."),
        ])
    }

    private static func emptyStreamingUpdates() -> AsyncStream<ParakeetStreamingUpdate> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func waitUntilOpened() async throws {
        try Task.checkCancellation()
        if isOpen { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        } onCancel: {
            Task {
                await self.open()
            }
        }
        try Task.checkCancellation()
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
