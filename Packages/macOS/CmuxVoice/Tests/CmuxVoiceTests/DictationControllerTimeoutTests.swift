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

/// Test-only fake; the test drives its continuations serially from the main actor.
private final class NeverFinishingTranscriber: SpeechTranscribing, @unchecked Sendable {
    private let releaseStream: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation
    private var eventContinuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?
    private(set) var finishStarted = false

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        releaseStream = stream
        releaseContinuation = continuation
    }

    func transcribe(
        locale: Locale
    ) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<DictationTranscriptionEvent, any Error>.makeStream()
        eventContinuation = continuation
        return stream
    }

    func finishTranscribing() async {
        finishStarted = true
        for await _ in releaseStream {}
        eventContinuation?.finish()
        eventContinuation = nil
    }

    func release() { releaseContinuation.finish() }
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

        for _ in 0..<10_000 {
            if controller.phase == .listening { break }
            await Task.yield()
        }
        #expect(controller.phase == .listening)

        controller.stop()
        for _ in 0..<10_000 {
            if controller.phase == .failed(.transcriptionFailed("dictation stop timed out")) {
                break
            }
            await Task.yield()
        }
        #expect(controller.phase == .failed(.transcriptionFailed("dictation stop timed out")))
        #expect(inserter.endCount == 1)

        // Let the cancelled finish task unwind so this test does not leave a
        // deliberately wedged fake alive beyond the test boundary.
        transcriber.release()
    }
}
