import Foundation
import Testing

@testable import CmuxVoice

private struct ImmediateClock: Clock, Sendable {
    struct Instant: InstantProtocol, Sendable {
        let value: Int

        func advanced(by duration: Duration) -> Instant { self }
        func duration(to other: Instant) -> Duration { .zero }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.value < rhs.value }
    }

    var now: Instant { Instant(value: 0) }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {}
}

private struct TimeoutAuthorizer: DictationAuthorizing {
    func microphoneAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestMicrophoneAuthorization() async -> Bool { true }
    func speechRecognitionAuthorization() async -> DictationAuthorizationStatus { .notRequired }
    func requestSpeechRecognitionAuthorization() async -> Bool { true }
}

@MainActor
private final class TimeoutInserter: DictationTextInserting {
    private(set) var beginCount = 0
    private(set) var endCount = 0

    func beginSession() async -> Bool {
        beginCount += 1
        return true
    }

    func insertFinalizedText(_: String) async -> Bool { true }

    func endSession() { endCount += 1 }
}

private actor TimeoutFinishGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

/// Test-only fake; the test drives its continuations serially from the main actor.
private final class NeverFinishingTranscriber: SpeechTranscribing, @unchecked Sendable {
    private let finishGate = TimeoutFinishGate()
    private var eventContinuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?
    private(set) var finishStarted = false
    private(set) var finishCompleted = false
    private(set) var finishWasCancelled = false
    private(set) var transcribeCount = 0

    func transcribe(
        locale: Locale
    ) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        transcribeCount += 1
        let (stream, continuation) = AsyncThrowingStream<DictationTranscriptionEvent, any Error>.makeStream()
        eventContinuation = continuation
        return stream
    }

    func finishTranscribing() async {
        finishStarted = true
        await finishGate.wait()
        finishWasCancelled = Task.isCancelled
        eventContinuation?.finish()
        eventContinuation = nil
        finishCompleted = true
    }

    func release() async { await finishGate.release() }
}

@MainActor
@Suite
struct DictationControllerTimeoutTests {
    @Test func stuckStopRecoversAtInjectedDeadline() async {
        let inserter = TimeoutInserter()
        let transcriber = NeverFinishingTranscriber()
        let controller = DictationController(
            authorizer: TimeoutAuthorizer(),
            inserter: inserter,
            makeTranscriber: { transcriber },
            localeProvider: { Locale(identifier: "en_US") },
            clock: ImmediateClock()
        )
        controller.start()

        _ = await dictationWaitUntil { controller.phase == .listening }
        #expect(controller.phase == .listening)

        controller.stop()
        _ = await dictationWaitUntil {
            controller.phase == .failed(.transcriptionFailed("dictation stop timed out"))
        }
        #expect(controller.phase == .failed(.transcriptionFailed("dictation stop timed out")))
        #expect(inserter.endCount == 1)

        // A non-cooperative finish occupies the single recovery slot; a
        // second start is refused instead of retaining another transcriber.
        controller.start()
        #expect(controller.phase == .failed(.transcriptionFailed("dictation stop timed out")))
        #expect(transcriber.transcribeCount == 1)

        // Let the cancelled finish task unwind so this test does not leave a
        // deliberately wedged fake alive beyond the test boundary.
        await transcriber.release()
        #expect(await dictationWaitUntil { transcriber.finishCompleted })
        #expect(transcriber.finishWasCancelled)
    }
}
