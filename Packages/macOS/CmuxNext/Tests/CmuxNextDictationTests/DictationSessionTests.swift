import Foundation
import Testing

@testable import CmuxNextDictation

/// Scripts each permission.
private struct FakeAuthorizer: DictationAuthorizing {
    var microphone: DictationAuthorizationStatus = .authorized
    var grantsMicrophone = true
    var speech: DictationAuthorizationStatus = .authorized

    func microphoneAuthorization() async -> DictationAuthorizationStatus { microphone }
    func requestMicrophoneAuthorization() async -> Bool { grantsMicrophone }
    func speechRecognitionAuthorization() async -> DictationAuthorizationStatus { speech }
    func requestSpeechRecognitionAuthorization() async -> Bool { speech == .authorized }
}

/// An engine the test drives: `send` yields events, and a finish ends the
/// stream unless `ignoresFinish` (an engine that never flushes).
private actor ScriptedEngine: SpeechTranscribing {
    private var continuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?
    private(set) var finishCount = 0
    private let failure: DictationFailure?
    private let ignoresFinish: Bool
    private let flush: [DictationTranscriptionEvent]

    init(failure: DictationFailure? = nil, ignoresFinish: Bool = false, flush: [DictationTranscriptionEvent] = []) {
        self.failure = failure
        self.ignoresFinish = ignoresFinish
        self.flush = flush
    }

    func transcribe(locale: Locale) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        if let failure { throw failure }
        let (stream, continuation) = AsyncThrowingStream<DictationTranscriptionEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        self.continuation = continuation
        return stream
    }

    func finishTranscribing() async {
        finishCount += 1
        guard !ignoresFinish else { return }
        for event in flush { continuation?.yield(event) }
        continuation?.finish()
    }

    func send(_ event: DictationTranscriptionEvent) { continuation?.yield(event) }
    func fail(_ failure: DictationFailure) { continuation?.finish(throwing: failure) }
}

@MainActor
private final class Harness {
    let session: DictationSession
    let engine: ScriptedEngine
    var updates: [DictationUpdate] = []

    init(authorizer: FakeAuthorizer = FakeAuthorizer(), engine: ScriptedEngine = ScriptedEngine(), stopDeadline: Duration = .seconds(5)) {
        self.engine = engine
        session = DictationSession(authorizer: authorizer, makeTranscriber: { _ in engine }, stopDeadline: stopDeadline)
        session.onUpdate = { [unowned self] in self.updates.append($0) }
    }

    var last: DictationUpdate? { updates.last }

    /// Waits until `condition` holds.
    func until(_ condition: @MainActor () async -> Bool) async {
        await eventually("last update \(String(describing: last))", condition)
    }

    func untilPhase(_ phase: DictationPhase) async {
        await until { session.phase == phase }
    }
}

@MainActor
@Suite(.serialized)
struct DictationSessionTests {
    @Test func startsIdleAndListensAfterStart() async {
        let harness = Harness()
        #expect(harness.session.phase == .idle)
        harness.session.start()
        #expect(harness.session.phase == .starting)
        await harness.untilPhase(.listening)
        #expect(harness.updates.map(\.phase) == [.starting, .listening])
    }

    @Test func streamsPartialsAndFinalsAsOneText() async {
        let harness = Harness()
        harness.session.start()
        await harness.untilPhase(.listening)
        await harness.engine.send(.partial("hello wor"))
        await harness.until { harness.last?.text == "hello wor" }
        await harness.engine.send(.final("hello world"))
        await harness.engine.send(.partial("again"))
        await harness.until { harness.last?.text == "hello world again" }
        #expect(harness.session.phase == .listening)
    }

    @Test func stopFinalizesAndKeepsTheText() async {
        let harness = Harness(engine: ScriptedEngine(flush: [.final("fix the bug")]))
        harness.session.start()
        await harness.untilPhase(.listening)
        await harness.engine.send(.partial("fix the"))
        await harness.until { harness.last?.text == "fix the" }
        harness.session.stop()
        #expect(harness.session.phase == .finalizing)
        await harness.untilPhase(.idle)
        #expect(harness.last == DictationUpdate(phase: .idle, text: "fix the bug"))
        #expect(await harness.engine.finishCount >= 1)
    }

    @Test func stopCommitsADanglingPartial() async {
        let harness = Harness()
        harness.session.start()
        await harness.untilPhase(.listening)
        await harness.engine.send(.partial("left over"))
        await harness.until { harness.last?.text == "left over" }
        harness.session.stop()
        await harness.untilPhase(.idle)
        #expect(harness.last == DictationUpdate(phase: .idle, text: "left over"))
    }

    @Test func stopDeadlineEndsAnEngineThatNeverFlushes() async {
        let harness = Harness(engine: ScriptedEngine(ignoresFinish: true), stopDeadline: .milliseconds(20))
        harness.session.start()
        await harness.untilPhase(.listening)
        await harness.engine.send(.partial("still here"))
        await harness.until { harness.last?.text == "still here" }
        harness.session.stop()
        // The deadline is a real 20 ms one-shot; yield until it fires.
        for _ in 0..<200 where harness.session.phase != .idle {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(harness.last == DictationUpdate(phase: .idle, text: "still here"))
    }

    @Test func cancelDiscardsAndReleasesTheEngine() async {
        let harness = Harness()
        harness.session.start()
        await harness.untilPhase(.listening)
        await harness.engine.send(.final("never mind"))
        await harness.until { harness.last?.text == "never mind" }
        harness.session.cancel()
        #expect(harness.session.phase == .idle)
        #expect(harness.last == DictationUpdate(phase: .idle, cancelled: true))
        await harness.until { await harness.engine.finishCount == 1 }
        // A late event from the cancelled session changes nothing.
        let count = harness.updates.count
        await harness.engine.send(.final("late"))
        for _ in 0..<50 { await Task.yield() }
        #expect(harness.updates.count == count)
    }

    @Test func stopWhileStartingCancels() async {
        let harness = Harness()
        harness.session.start()
        harness.session.stop()
        #expect(harness.session.phase == .idle)
        #expect(harness.last?.cancelled == true)
        for _ in 0..<50 { await Task.yield() }
        #expect(harness.session.phase == .idle)
    }

    @Test func toggleStartsThenStops() async {
        let harness = Harness()
        harness.session.toggle()
        await harness.untilPhase(.listening)
        harness.session.toggle()
        await harness.untilPhase(.idle)
        #expect(harness.last?.cancelled == false)
    }

    @Test func deniedMicrophoneRestsInDenied() async {
        let harness = Harness(authorizer: FakeAuthorizer(microphone: .denied))
        harness.session.start()
        await harness.untilPhase(.denied(.microphone))
        #expect(await harness.engine.finishCount == 0)
        // Denied is startable again: the user may have fixed it in System Settings.
        #expect(harness.session.phase.isStartable)
    }

    @Test func refusedMicrophonePromptIsDenied() async {
        let harness = Harness(authorizer: FakeAuthorizer(microphone: .undetermined, grantsMicrophone: false))
        harness.session.start()
        await harness.untilPhase(.denied(.microphone))
    }

    @Test func grantedMicrophonePromptListens() async {
        let harness = Harness(authorizer: FakeAuthorizer(microphone: .undetermined, grantsMicrophone: true))
        harness.session.start()
        await harness.untilPhase(.listening)
    }

    @Test func deniedSpeechRecognitionFromTheEngineIsDenied() async {
        let harness = Harness(engine: ScriptedEngine(failure: .speechRecognitionAccessDenied))
        harness.session.start()
        await harness.untilPhase(.denied(.speechRecognition))
    }

    @Test func engineStartFailureRestsInFailed() async {
        let failure = DictationFailure.onDeviceRecognitionUnavailable(localeIdentifier: "xx")
        let harness = Harness(engine: ScriptedEngine(failure: failure))
        harness.session.start()
        await harness.untilPhase(.failed(failure))
        harness.session.start()
        #expect(harness.session.phase == .starting)
    }

    @Test func midSessionFailureKeepsWhatWasHeard() async {
        let harness = Harness()
        harness.session.start()
        await harness.untilPhase(.listening)
        await harness.engine.send(.final("first part"))
        await harness.engine.send(.partial("and the"))
        await harness.until { harness.last?.text == "first part and the" }
        await harness.engine.fail(.audioCaptureFailed("unplugged"))
        await harness.untilPhase(.failed(.audioCaptureFailed("unplugged")))
        // The live words stay too: the composer keeps what was on screen.
        #expect(harness.last?.text == "first part and the")
        await harness.until { await harness.engine.finishCount == 1 }
    }

    @Test func startIsIgnoredWhileListening() async {
        let harness = Harness()
        harness.session.start()
        await harness.untilPhase(.listening)
        let count = harness.updates.count
        harness.session.start()
        #expect(harness.updates.count == count)
    }
}
