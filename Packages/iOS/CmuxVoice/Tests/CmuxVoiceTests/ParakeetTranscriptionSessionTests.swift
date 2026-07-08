import Foundation
import Testing
@testable import CmuxVoice

@Suite struct ParakeetTranscriptionSessionTests {
    private static let startupTimedOut = "Voice transcription is still loading. Try again in a moment."

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
            .failed(Self.startupTimedOut),
        ])
    }

    @Test func startupWatchdogReportsFailureWhenStartupHangs() async {
        let startupGate = AsyncGate()
        let timeoutGate = AsyncGate()
        let cancelCounter = AsyncCounter()
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
            cancelManager: {
                await cancelCounter.increment()
            }
        )

        let updatesTask = Self.collectUpdates(from: session.updates)

        await timeoutGate.open()

        let updates = await updatesTask.value
        #expect(updates == [.failed(Self.startupTimedOut)])
        #expect(await cancelCounter.value == 1)
    }

    @Test func startupCompletesBeforeWatchdogAndPartialsFlow() async {
        let startupGate = AsyncGate()
        let timeoutGate = AsyncGate()
        let (streamingUpdates, streamingContinuation) = AsyncStream<ParakeetStreamingUpdate>.makeStream()
        let session = ParakeetTranscriptionSession(
            sleepForStartupDeadline: { _ in
                try await timeoutGate.waitUntilOpened()
            },
            startup: {
                try await startupGate.waitUntilOpened()
                return true
            },
            transcriptionUpdates: streamingUpdates,
            streamAudioToManager: { _ in },
            finishTranscript: { "done" },
            cancelManager: {}
        )

        let updatesStream = session.updates
        let firstUpdate = Task {
            var iterator = updatesStream.makeAsyncIterator()
            return await iterator.next()
        }

        await startupGate.open()
        streamingContinuation.yield(ParakeetStreamingUpdate(text: "hello cmux", isConfirmed: false))

        #expect(await firstUpdate.value == .partial("hello cmux"))
        session.cancel()
        streamingContinuation.finish()
    }

    @Test func watchdogAndFinishRaceSettlesOnce() async {
        let startupGate = AsyncGate()
        let timeoutGate = AsyncGate()
        let cancelCounter = AsyncCounter()
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
            cancelManager: {
                await cancelCounter.increment()
            }
        )

        let updatesTask = Self.collectUpdates(from: session.updates)

        session.finish()
        await timeoutGate.open()

        let updates = await updatesTask.value
        #expect(updates == [.failed(Self.startupTimedOut)])
        #expect(await cancelCounter.value == 1)
    }

    @Test func cancelBeforeWatchdogDeadlineEmitsNothing() async {
        let startupGate = AsyncGate()
        let timeoutGate = AsyncGate()
        let cancelCounter = AsyncCounter()
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
            cancelManager: {
                await cancelCounter.increment()
            }
        )

        let updatesTask = Self.collectUpdates(from: session.updates)

        session.cancel()
        await timeoutGate.open()

        let updates = await updatesTask.value
        #expect(updates.isEmpty)
        #expect(await cancelCounter.value == 1)
    }

    private static func emptyStreamingUpdates() -> AsyncStream<ParakeetStreamingUpdate> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    private static func collectUpdates(from stream: AsyncStream<VoiceTranscriptionUpdate>) -> Task<[VoiceTranscriptionUpdate], Never> {
        Task {
            var updates: [VoiceTranscriptionUpdate] = []
            for await update in stream {
                updates.append(update)
            }
            return updates
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

private actor AsyncCounter {
    private var count = 0

    var value: Int { count }

    func increment() {
        count += 1
    }
}
