import Foundation
import Testing

@testable import CmuxVoice

/// Scripts authorization statuses for every controller path.
private struct FakeAuthorizer: DictationAuthorizing {
    var microphone: DictationAuthorizationStatus = .authorized
    var microphoneRequestGrants = true
    var speech: DictationAuthorizationStatus = .notRequired
    var speechRequestGrants = true

    func microphoneAuthorization() async -> DictationAuthorizationStatus { microphone }
    func requestMicrophoneAuthorization() async -> Bool { microphoneRequestGrants }
    func speechRecognitionAuthorization() async -> DictationAuthorizationStatus { speech }
    func requestSpeechRecognitionAuthorization() async -> Bool { speechRequestGrants }
}

/// Records inserted deltas; can simulate a vanished target.
@MainActor
private final class RecordingInserter: DictationTextInserting {
    var beginSucceeds = true
    var insertionSucceedsAfter: Int = .max
    private(set) var began = 0
    private(set) var ended = 0
    private(set) var insertions: [String] = []

    func beginSession() -> Bool {
        began += 1
        return beginSucceeds
    }

    func insertFinalizedText(_ text: String) -> Bool {
        guard insertions.count < insertionSucceedsAfter else { return false }
        insertions.append(text)
        return true
    }

    func endSession() {
        ended += 1
    }
}

/// A transcriber whose event stream is driven by the test.
private final class ScriptedTranscriber: SpeechTranscribing, @unchecked Sendable {
    // Continuation is assigned once in transcribe() before any test sends
    // events; tests drive a single controller session at a time.
    private var continuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?
    private let startError: (any Error)?
    let finishFlush: [DictationTranscriptionEvent]

    init(startError: (any Error)? = nil, finishFlush: [DictationTranscriptionEvent] = []) {
        self.startError = startError
        self.finishFlush = finishFlush
    }

    func transcribe(
        locale: Locale
    ) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        if let startError { throw startError }
        let (stream, continuation) = AsyncThrowingStream<DictationTranscriptionEvent, any Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func finishTranscribing() async {
        for event in finishFlush {
            continuation?.yield(event)
        }
        continuation?.finish()
        continuation = nil
    }

    func send(_ event: DictationTranscriptionEvent) {
        continuation?.yield(event)
    }

    func fail(_ error: any Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}

@MainActor
private final class FailureRecorder {
    private(set) var failures: [DictationFailure] = []
    func record(_ failure: DictationFailure) { failures.append(failure) }
}

/// Polls the main actor until a condition holds, yielding between checks.
/// Deterministic: no wall-clock sleeps, just cooperative yields with a
/// bounded iteration count.
@MainActor
private func waitUntil(
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
struct DictationControllerTests {
    private func makeController(
        authorizer: FakeAuthorizer = FakeAuthorizer(),
        inserter: RecordingInserter = RecordingInserter(),
        transcriber: ScriptedTranscriber = ScriptedTranscriber()
    ) -> (DictationController, RecordingInserter, ScriptedTranscriber, FailureRecorder) {
        let recorder = FailureRecorder()
        let controller = DictationController(
            authorizer: authorizer,
            inserter: inserter,
            makeTranscriber: { transcriber },
            localeProvider: { Locale(identifier: "en_US") }
        )
        controller.failureHandler = { recorder.record($0) }
        return (controller, inserter, transcriber, recorder)
    }

    @Test func successfulSessionInsertsFinalsAndReturnsToIdle() async {
        let (controller, inserter, transcriber, recorder) = makeController()
        controller.toggle()
        #expect(await waitUntil { controller.phase == .listening })
        #expect(inserter.began == 1)

        transcriber.send(.partial("hel"))
        #expect(await waitUntil { controller.transcript.volatileText == "hel" })
        #expect(inserter.insertions.isEmpty)

        transcriber.send(.final("hello"))
        #expect(await waitUntil { inserter.insertions == ["hello"] })

        transcriber.send(.final("world"))
        #expect(await waitUntil { inserter.insertions == ["hello", " world"] })

        controller.toggle()
        #expect(await waitUntil { controller.phase == .idle })
        #expect(inserter.ended == 1)
        #expect(recorder.failures.isEmpty)
    }

    @Test func stopFlushesEngineFinalsBeforeEnding() async {
        let transcriber = ScriptedTranscriber(finishFlush: [.final("tail")])
        let (controller, inserter, _, _) = makeController(transcriber: transcriber)
        controller.toggle()
        #expect(await waitUntil { controller.phase == .listening })

        controller.toggle()
        #expect(await waitUntil { controller.phase == .idle })
        #expect(inserter.insertions == ["tail"])
    }

    @Test func danglingPartialIsCommittedAtSessionEnd() async {
        let (controller, inserter, transcriber, _) = makeController()
        controller.toggle()
        #expect(await waitUntil { controller.phase == .listening })

        transcriber.send(.partial("dangling"))
        #expect(await waitUntil { controller.transcript.volatileText == "dangling" })

        controller.stop()
        #expect(await waitUntil { controller.phase == .idle })
        #expect(inserter.insertions == ["dangling"])
    }

    @Test func microphoneDenialFailsWithoutStartingEngine() async {
        var authorizer = FakeAuthorizer()
        authorizer.microphone = .denied
        let (controller, inserter, _, recorder) = makeController(authorizer: authorizer)
        controller.toggle()
        #expect(await waitUntil { controller.phase == .failed(.microphoneAccessDenied) })
        #expect(recorder.failures == [.microphoneAccessDenied])
        #expect(inserter.began == 0)
        #expect(controller.isActive == false)
    }

    @Test func microphoneRequestDeclinedFails() async {
        var authorizer = FakeAuthorizer()
        authorizer.microphone = .undetermined
        authorizer.microphoneRequestGrants = false
        let (controller, _, _, recorder) = makeController(authorizer: authorizer)
        controller.toggle()
        #expect(await waitUntil { controller.phase == .failed(.microphoneAccessDenied) })
        #expect(recorder.failures == [.microphoneAccessDenied])
    }

    @Test func speechRecognitionDenialFails() async {
        var authorizer = FakeAuthorizer()
        authorizer.speech = .denied
        let (controller, _, _, recorder) = makeController(authorizer: authorizer)
        controller.toggle()
        #expect(await waitUntil { controller.phase == .failed(.speechRecognitionAccessDenied) })
        #expect(recorder.failures == [.speechRecognitionAccessDenied])
    }

    @Test func missingInsertionTargetFails() async {
        let inserter = RecordingInserter()
        inserter.beginSucceeds = false
        let (controller, _, _, recorder) = makeController(inserter: inserter)
        controller.toggle()
        #expect(await waitUntil { controller.phase == .failed(.insertionTargetUnavailable) })
        #expect(recorder.failures == [.insertionTargetUnavailable])
    }

    @Test func vanishedTargetMidSessionFailsAndStopsEngine() async {
        let inserter = RecordingInserter()
        inserter.insertionSucceedsAfter = 1
        let (controller, _, transcriber, recorder) = makeController(inserter: inserter)
        controller.toggle()
        #expect(await waitUntil { controller.phase == .listening })

        transcriber.send(.final("first"))
        #expect(await waitUntil { inserter.insertions == ["first"] })

        transcriber.send(.final("second"))
        #expect(await waitUntil { controller.phase == .failed(.insertionTargetUnavailable) })
        #expect(recorder.failures == [.insertionTargetUnavailable])
        #expect(inserter.ended == 1)
    }

    @Test func transcriberStartFailureSurfacesAsFailedPhase() async {
        let transcriber = ScriptedTranscriber(
            startError: DictationFailure.onDeviceRecognitionUnavailable(localeIdentifier: "xx_XX")
        )
        let (controller, _, _, recorder) = makeController(transcriber: transcriber)
        controller.toggle()
        let expected = DictationFailure.onDeviceRecognitionUnavailable(localeIdentifier: "xx_XX")
        #expect(await waitUntil { controller.phase == .failed(expected) })
        #expect(recorder.failures == [expected])
    }

    @Test func streamErrorMidSessionFails() async {
        let (controller, _, transcriber, recorder) = makeController()
        controller.toggle()
        #expect(await waitUntil { controller.phase == .listening })

        transcriber.fail(DictationFailure.transcriptionFailed("boom"))
        #expect(await waitUntil { controller.phase == .failed(.transcriptionFailed("boom")) })
        #expect(recorder.failures == [.transcriptionFailed("boom")])
    }

    @Test func toggleAfterFailureStartsFreshSession() async {
        let inserter = RecordingInserter()
        inserter.beginSucceeds = false
        let (controller, _, _, _) = makeController(inserter: inserter)
        controller.toggle()
        #expect(await waitUntil { controller.phase == .failed(.insertionTargetUnavailable) })

        inserter.beginSucceeds = true
        controller.toggle()
        #expect(await waitUntil { controller.phase == .listening })
        #expect(inserter.began == 2)
    }

    @Test func startWhileActiveIsIgnored() async {
        let (controller, inserter, _, _) = makeController()
        controller.toggle()
        #expect(await waitUntil { controller.phase == .listening })
        controller.start()
        #expect(controller.phase == .listening)
        #expect(inserter.began == 1)
    }
}
