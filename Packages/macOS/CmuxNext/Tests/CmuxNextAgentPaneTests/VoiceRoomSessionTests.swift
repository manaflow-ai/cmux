import CmuxNextDictation
import CmuxNextWakeupsTestSupport
import Testing

@MainActor
private final class FakeDictation: VoiceRoomDictating {
    var phase: DictationPhase = .idle
    var onUpdate: ((DictationUpdate) -> Void)?
    var starts = 0
    var cancels = 0

    func start() {
        starts += 1
        phase = .listening
    }

    func cancel() {
        cancels += 1
        phase = .idle
    }

    func say(_ text: String, level: Float = 0.5) {
        onUpdate?(DictationUpdate(phase: .listening, text: text, level: level))
    }

    func end(_ text: String) {
        phase = .idle
        onUpdate?(DictationUpdate(phase: .idle, text: text))
    }
}

/// Records each posted line and hands it to the test in order.
private actor FakePoster: VoiceRoomPosting {
    nonisolated let posted: AsyncStream<VoiceRoomLine>
    private let continuation: AsyncStream<VoiceRoomLine>.Continuation
    private var pausedReply = false

    init() {
        (posted, continuation) = AsyncStream.makeStream()
    }

    func replyPaused(_ paused: Bool) { pausedReply = paused }

    func post(_ line: VoiceRoomLine) async throws -> Bool {
        continuation.yield(line)
        return pausedReply
    }
}

private struct FakeEvents: VoiceRoomEventSource {
    let stream: AsyncStream<Bool>
    let continuation: AsyncStream<Bool>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func pauses() -> AsyncStream<Bool> { stream }
}

private actor FakeScreen: VoiceRoomScreenReading {
    private var texts: [String]

    init(_ texts: [String]) { self.texts = texts }

    @concurrent
    nonisolated func read(changedSince previous: VoiceRoomFrameSignature?) async throws -> VoiceRoomScreenSample? {
        guard let text = await next() else { return nil }
        let pixels = [UInt8](repeating: UInt8(text.count % 255), count: VoiceRoomFrameSignature.width * VoiceRoomFrameSignature.height)
        guard let signature = VoiceRoomFrameSignature(pixels: pixels) else { return nil }
        return VoiceRoomScreenSample(signature: signature, text: text)
    }

    private func next() -> String? { texts.isEmpty ? nil : texts.removeFirst() }
}

@MainActor
@Suite struct VoiceRoomSessionTests {
    @Test func finishedSentencesGoToTheRoomInOrder() async {
        let dictation = FakeDictation()
        let poster = FakePoster()
        let session = VoiceRoomSession(dictation: { dictation }, poster: poster, events: FakeEvents(), screen: nil)
        session.start()
        #expect(session.state == .listening)
        #expect(dictation.starts == 1)
        dictation.say("Chief, check CI. And", level: 0.7)
        dictation.say("Chief, check CI. And then open the PR. Bye")
        var lines = poster.posted.makeAsyncIterator()
        #expect(await lines.next() == VoiceRoomLine(kind: .speech, text: "Chief, check CI.", level: 0.7))
        #expect(await lines.next()?.text == "And then open the PR.")
        session.stop()
        #expect(session.state == .off)
        #expect(dictation.cancels == 1)
    }

    @Test func theEngineRestartsWhenItEndsAndGivesUpAfterThreeEmptyEnds() async {
        let dictation = FakeDictation()
        let poster = FakePoster()
        let session = VoiceRoomSession(dictation: { dictation }, poster: poster, events: FakeEvents(), screen: nil)
        session.start()
        dictation.end("Last words")
        var lines = poster.posted.makeAsyncIterator()
        #expect(await lines.next()?.text == "Last words")
        #expect(dictation.starts == 2)
        dictation.end("")
        dictation.end("")
        #expect(session.state == .listening)
        dictation.end("")
        #expect(session.state == .failed(.dictationStopped))
    }

    @Test func aDeniedMicStopsTheSession() {
        let dictation = FakeDictation()
        let session = VoiceRoomSession(dictation: { dictation }, poster: FakePoster(), events: FakeEvents(), screen: nil)
        session.start()
        dictation.onUpdate?(DictationUpdate(phase: .denied(.microphone)))
        #expect(session.state == .failed(.denied(.microphone)))
    }

    @Test func theRoomsPauseStopsListeningUntilItResumes() async {
        let dictation = FakeDictation()
        let events = FakeEvents()
        let poster = FakePoster()
        let session = VoiceRoomSession(dictation: { dictation }, poster: poster, events: events, screen: nil)
        session.start()
        events.continuation.yield(true)
        await waitUntil { session.state == .paused }
        #expect(dictation.cancels == 1)
        // Words heard while paused go nowhere.
        dictation.say("private. words")
        events.continuation.yield(false)
        await waitUntil { session.state == .listening }
        #expect(dictation.starts == 2)
        dictation.say("Back on. Yes")
        var lines = poster.posted.makeAsyncIterator()
        #expect(await lines.next()?.text == "Back on.")
        session.stop()
    }

    @Test func aPausedReplyFromTheRoomPausesTheSession() async {
        let dictation = FakeDictation()
        let poster = FakePoster()
        await poster.replyPaused(true)
        let session = VoiceRoomSession(dictation: { dictation }, poster: poster, events: FakeEvents(), screen: nil)
        session.start()
        dictation.say("One. Two")
        var lines = poster.posted.makeAsyncIterator()
        _ = await lines.next()
        await waitUntil { session.state == .paused }
        #expect(session.linesSent == 0)
    }

    @Test func screenTextGoesOnTheScreenCadence() async throws {
        let clock = ManualClock()
        let poster = FakePoster()
        let session = VoiceRoomSession(dictation: { FakeDictation() }, poster: poster, events: FakeEvents(),
                                       screen: FakeScreen(["Xcode — Build Failed", ""]), screenInterval: .seconds(5), clock: clock)
        session.start()
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        var lines = poster.posted.makeAsyncIterator()
        #expect(await lines.next() == VoiceRoomLine(kind: .screen, text: "Xcode — Build Failed"))
        session.stop()
    }

    /// Lets the session's tasks run until `condition` holds (each yield is one hop of the main actor).
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }
}
