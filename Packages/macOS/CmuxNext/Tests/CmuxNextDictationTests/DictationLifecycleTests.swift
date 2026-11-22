import Foundation
import Synchronization
import Testing

@testable import CmuxNextDictation

/// A permission the test changes between sessions (System Settings).
private final class SettingsAuthorizer: DictationAuthorizing {
    let microphone = Mutex(DictationAuthorizationStatus.denied)
    func microphoneAuthorization() async -> DictationAuthorizationStatus { microphone.withLock { $0 } }
    func requestMicrophoneAuthorization() async -> Bool { microphone.withLock { $0 == .authorized } }
    func speechRecognitionAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestSpeechRecognitionAuthorization() async -> Bool { true }
}

private struct Granting: DictationAuthorizing {
    func microphoneAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestMicrophoneAuthorization() async -> Bool { true }
    func speechRecognitionAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestSpeechRecognitionAuthorization() async -> Bool { true }
}

/// One engine per session, each counting its finishes: the microphone is
/// released once the session's engine has been finished.
private actor Engine: SpeechTranscribing {
    private var continuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?
    private(set) var finishes = 0
    private(set) var started = false

    func transcribe(locale: Locale) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<DictationTranscriptionEvent, any Error>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.continuation = continuation
        started = true
        return stream
    }

    func finishTranscribing() async {
        finishes += 1
        continuation?.finish()
    }

    /// Started and never finished: still holding the microphone.
    var isOpen: Bool { started && finishes == 0 }

    func send(_ event: DictationTranscriptionEvent) { continuation?.yield(event) }
    /// Another app took the input device, or it went away.
    func lose(_ failure: DictationFailure) { continuation?.finish(throwing: failure) }
}

@MainActor
private final class Rig {
    private final class Made { var engines: [Engine] = [] }
    private let made_: Made
    var updates: [DictationUpdate] = []
    let session: DictationSession

    init(authorizer: any DictationAuthorizing = Granting(), stopDeadline: Duration = .seconds(5)) {
        let made = Made()
        made_ = made
        session = DictationSession(authorizer: authorizer, makeTranscriber: { _ in
            let engine = Engine()
            made.engines.append(engine)
            return engine
        }, stopDeadline: stopDeadline)
        session.onUpdate = { [unowned self] in self.updates.append($0) }
    }

    var made: [Engine] { made_.engines }
    var last: DictationUpdate? { updates.last }

    func until(_ what: String = "", _ condition: @MainActor () async -> Bool) async {
        await eventually("\(what); phase \(session.phase), last \(String(describing: last))", condition)
    }

    /// Every engine any session made has been finished (its microphone released),
    /// and the session holds nothing.
    func expectReleased() async {
        await until("released") {
            for engine in made {
                if await engine.isOpen { return false }
            }
            return !session.holdsResources
        }
        #expect(session.phase.isStartable)
    }
}

@MainActor
@Suite(.serialized)
struct DictationLifecycleTests {
    @Test func startStopReleasesTheMicrophone() async {
        let rig = Rig()
        rig.session.start()
        await rig.until { rig.session.phase == .listening }
        await rig.made[0].send(.final("hello"))
        await rig.until { rig.last?.text == "hello" }
        rig.session.stop()
        await rig.until { rig.session.phase == .idle }
        #expect(rig.last == DictationUpdate(phase: .idle, text: "hello"))
        await rig.expectReleased()
    }

    /// Mashing the mic: every press lands, sessions never overlap, and the
    /// last press decides. No engine stays open.
    @Test func rapidTogglingLeavesOneOutcomeAndNoOpenEngine() async {
        let rig = Rig()
        for _ in 0..<7 { rig.session.toggle() }
        // Odd number of presses from idle: start, cancel, start, ... ends starting.
        await rig.until { rig.session.phase == .listening }
        try? await Task.sleep(for: .milliseconds(20))
        let open = await rig.made.asyncFilter { await $0.isOpen }
        #expect(open.count == 1)
        rig.session.toggle()
        await rig.until { rig.session.phase == .idle }
        await rig.expectReleased()
    }

    @Test func rapidToggleWhileListeningThenStartingAgain() async {
        let rig = Rig()
        rig.session.start()
        await rig.until { rig.session.phase == .listening }
        rig.session.toggle()
        rig.session.toggle()
        rig.session.toggle()
        // stop, (finalizing: ignored), (finalizing: ignored): one stop wins.
        await rig.until { rig.session.phase == .idle }
        rig.session.start()
        await rig.until { rig.session.phase == .listening }
        rig.session.cancel()
        await rig.expectReleased()
        #expect(rig.made.count == 2)
    }

    /// Push-to-talk released mid-phrase: the half-spoken hypothesis is kept.
    @Test func releaseMidPhraseKeepsTheWordsHeardSoFar() async {
        let rig = Rig()
        rig.session.start()
        await rig.until { rig.session.phase == .listening }
        await rig.made[0].send(.final("open the"))
        await rig.made[0].send(.partial("settings fi"))
        await rig.until { rig.last?.text == "open the settings fi" }
        rig.session.stop()
        await rig.until { rig.session.phase == .idle }
        #expect(rig.last?.text == "open the settings fi")
        await rig.expectReleased()
    }

    /// Another app takes the microphone (or the device goes away): the
    /// session fails with what it heard, lets go, and can start again.
    @Test func microphoneTakenMidSessionFailsKeepsTextAndRecovers() async {
        let rig = Rig()
        rig.session.start()
        await rig.until { rig.session.phase == .listening }
        await rig.made[0].send(.final("first part"))
        await rig.until { rig.last?.text == "first part" }
        await rig.made[0].lose(.audioCaptureFailed("device taken"))
        await rig.until { rig.session.phase == .failed(.audioCaptureFailed("device taken")) }
        #expect(rig.last?.text == "first part")
        await rig.expectReleased()
        rig.session.start()
        await rig.until { rig.session.phase == .listening }
        rig.session.cancel()
        await rig.expectReleased()
    }

    /// Denied, then the user grants it in System Settings: the next press works.
    @Test func deniedThenGrantedLater() async {
        let authorizer = SettingsAuthorizer()
        let rig = Rig(authorizer: authorizer)
        rig.session.start()
        await rig.until { rig.session.phase == .denied(.microphone) }
        #expect(rig.made.isEmpty)
        #expect(!rig.session.holdsResources)
        authorizer.microphone.withLock { $0 = .authorized }
        rig.session.start()
        await rig.until { rig.session.phase == .listening }
        rig.session.stop()
        await rig.expectReleased()
    }

    @Test func cancelWhileStartingLeavesNothingOpen() async {
        let rig = Rig()
        rig.session.start()
        rig.session.cancel()
        #expect(rig.last?.cancelled == true)
        await rig.expectReleased()
    }

    @Test func stopDeadlineReleasesEverything() async {
        let rig = Rig(stopDeadline: .milliseconds(10))
        rig.session.start()
        await rig.until { rig.session.phase == .listening }
        rig.session.stop()
        await rig.until { rig.session.phase == .idle }
        await rig.expectReleased()
    }

    /// Updates from a session that already ended never reach the composer.
    @Test func lateEventsAfterCancelChangeNothing() async {
        let rig = Rig()
        rig.session.start()
        await rig.until { rig.session.phase == .listening }
        let first = rig.made[0]
        rig.session.cancel()
        let count = rig.updates.count
        await first.send(.final("ghost"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(rig.updates.count == count)
    }
}

extension Array {
    fileprivate func asyncFilter(_ keep: (Element) async -> Bool) async -> [Element] {
        var kept: [Element] = []
        for element in self {
            if await keep(element) { kept.append(element) }
        }
        return kept
    }
}
