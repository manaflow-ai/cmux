import Foundation
import Testing

@testable import CmuxVoice

private struct FinishBarrierAuthorizer: DictationAuthorizing {
    func microphoneAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestMicrophoneAuthorization() async -> Bool { true }
    func speechRecognitionAuthorization() async -> DictationAuthorizationStatus { .notRequired }
    func requestSpeechRecognitionAuthorization() async -> Bool { true }
}

@MainActor
private final class FinishBarrierInserter: DictationTextInserting {
    private(set) var endCount = 0

    func beginSession() async -> Bool { true }
    func insertFinalizedText(_: String) async -> Bool { true }
    func endSession() { endCount += 1 }
}

/// Keeps the first engine's finish operation open while its outward stream
/// ends, allowing the test to prove that a successor waits for cleanup.
private final class FinishBarrierTranscriber: SpeechTranscribing, @unchecked Sendable {
    private var eventContinuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?
    private let finishGate: AsyncStream<Void>
    private let finishGateContinuation: AsyncStream<Void>.Continuation
    private(set) var finishStarted = false
    private(set) var transcribeCount = 0

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        finishGate = stream
        finishGateContinuation = continuation
    }

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
        for await _ in finishGate {}
        eventContinuation?.finish()
        eventContinuation = nil
    }

    func endStream() {
        eventContinuation?.finish()
        eventContinuation = nil
    }

    func releaseFinish() {
        finishGateContinuation.finish()
    }
}

@MainActor
private func finishBarrierWaitUntil(
    _ condition: @MainActor () -> Bool,
    iterations: Int = 10_000
) async -> Bool {
    for _ in 0..<iterations {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
@Suite
struct DictationControllerFinishBarrierTests {
    @Test func successorStartsOnlyAfterPriorFinishReturns() async {
        let first = FinishBarrierTranscriber()
        let second = FinishBarrierTranscriber()
        let inserter = FinishBarrierInserter()
        var factoryCalls = 0
        let controller = DictationController(
            authorizer: FinishBarrierAuthorizer(),
            inserter: inserter,
            makeTranscriber: {
                factoryCalls += 1
                return factoryCalls == 1 ? first : second
            },
            localeProvider: { Locale(identifier: "en_US") }
        )

        controller.start()
        #expect(await finishBarrierWaitUntil { controller.phase == .listening })
        controller.stop()
        #expect(await finishBarrierWaitUntil { first.finishStarted })

        // The stream may terminate before engine cleanup returns. The first
        // session settles, but no successor engine may start yet.
        first.endStream()
        #expect(await finishBarrierWaitUntil { controller.phase == .idle })
        controller.start()
        await Task.yield()
        #expect(second.transcribeCount == 0)

        first.releaseFinish()
        #expect(await finishBarrierWaitUntil { second.transcribeCount == 1 })
        #expect(await finishBarrierWaitUntil { controller.phase == .listening })
        controller.stop()
        second.releaseFinish()
        #expect(await finishBarrierWaitUntil { controller.phase == .idle })
        #expect(inserter.endCount == 2)
    }
}
