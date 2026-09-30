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
    private(set) var finishCompleted = false
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
        finishCompleted = true
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
private func finishBarrierWaitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    await dictationWaitUntil(condition)
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
        #expect(second.transcribeCount == 0)

        first.releaseFinish()
        #expect(await finishBarrierWaitUntil { first.finishCompleted })
        #expect(await finishBarrierWaitUntil { second.transcribeCount == 1 })
        #expect(await finishBarrierWaitUntil { controller.phase == .listening })
        controller.stop()
        second.releaseFinish()
        #expect(await finishBarrierWaitUntil { controller.phase == .idle })
        #expect(inserter.endCount == 2)
    }

    /// A hold-to-talk release that lands while the start is still queued
    /// must cancel it, or the microphone opens after the key is up.
    @Test func stopCancelsQueuedStart() async {
        let first = FinishBarrierTranscriber()
        let second = FinishBarrierTranscriber()
        var factoryCalls = 0
        let controller = DictationController(
            authorizer: FinishBarrierAuthorizer(),
            inserter: FinishBarrierInserter(),
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
        first.endStream()
        #expect(await finishBarrierWaitUntil { controller.phase == .idle })

        controller.start()
        #expect(controller.isActiveOrStarting)
        #expect(!controller.isActive)
        controller.stop()
        #expect(!controller.isActiveOrStarting)

        first.releaseFinish()
        #expect(await finishBarrierWaitUntil { first.finishCompleted })
        #expect(await finishBarrierWaitUntil { !controller.isActiveOrStarting })
        #expect(second.transcribeCount == 0)
        #expect(controller.phase == .idle)
    }
}
