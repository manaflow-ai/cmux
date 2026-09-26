import Foundation
import Testing
@testable import CmuxDictation

/// Scripted recognition session for controller tests. Single-threaded: the
/// test drives `emit` directly, so plain mutable flags are sound here.
private final class FakeDictationSession: DictationRecognizing, @unchecked Sendable {
    let stream: AsyncStream<DictationRecognitionEvent>
    let continuation: AsyncStream<DictationRecognitionEvent>.Continuation
    private(set) var finishCallCount = 0
    private(set) var cancelCallCount = 0

    init() {
        var continuation: AsyncStream<DictationRecognitionEvent>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func start() -> AsyncStream<DictationRecognitionEvent> { stream }

    func finish() {
        finishCallCount += 1
    }

    func cancel() {
        cancelCallCount += 1
        continuation.finish()
    }

    func emit(_ event: DictationRecognitionEvent) {
        continuation.yield(event)
    }
}

/// Records inserted transcripts. Confined to the main actor per the protocol.
private final class RecordingSink: DictationTextSink, @unchecked Sendable {
    var inserted: [String] = []

    func insertDictationText(_ text: String) -> Bool {
        inserted.append(text)
        return true
    }
}

@MainActor
@Suite
struct DictationControllerTests {
    /// Awaits until the controller reaches the phase; recognition starts are
    /// async (`Task { await beginRecognition() }`), so callers must settle.
    private func waitForPhase(
        _ controller: DictationController,
        _ phase: DictationController.Phase,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        let start = ContinuousClock.now
        while controller.phase != phase {
            if ContinuousClock.now - start > timeout { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(10))
    }

    private func makeController(
        session: FakeDictationSession,
        sink: RecordingSink,
        outcome: DictationAuthorizationOutcome = .granted,
        finalizeTimeout: Duration = .seconds(2.5)
    ) -> DictationController {
        DictationController(
            makeSession: { session },
            sink: sink,
            authorization: DictationAuthorization(
                resolve: { outcome },
                request: { outcome != .denied }
            ),
            finalizeTimeout: finalizeTimeout
        )
    }

    @Test("Partials surface on the controller; final inserts once and settles")
    func partialThenFinalInserts() async {
        let session = FakeDictationSession()
        let sink = RecordingSink()
        let controller = makeController(session: session, sink: sink)

        controller.toggle()
        #expect(await waitForPhase(controller, .listening))

        session.emit(.partial("hello wor"))
        await Task.yield()
        #expect(controller.partialTranscript == "hello wor")

        session.emit(.final("hello world"))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(sink.inserted == ["hello world"])
        #expect(controller.phase == .idle)
        #expect(controller.partialTranscript.isEmpty)
    }

    @Test("Toggle while listening finishes gracefully")
    func toggleFinishesGracefully() async {
        let session = FakeDictationSession()
        let sink = RecordingSink()
        let controller = makeController(session: session, sink: sink)

        controller.toggle()
        #expect(await waitForPhase(controller, .listening))
        controller.toggle()
        #expect(controller.phase == .stopping)
        await settle()
        #expect(session.finishCallCount == 1)

        session.emit(.final("done"))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(sink.inserted == ["done"])
        #expect(controller.phase == .idle)
    }

    @Test("Hold flow starts on press and inserts on release-final")
    func holdFlowInserts() async {
        let session = FakeDictationSession()
        let sink = RecordingSink()
        let controller = makeController(session: session, sink: sink)

        controller.beginHold()
        #expect(await waitForPhase(controller, .listening))
        controller.endHold()
        #expect(controller.phase == .stopping)
        await settle()
        #expect(session.finishCallCount == 1)

        session.emit(.final("push to talk"))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(sink.inserted == ["push to talk"])
        #expect(controller.phase == .idle)
    }

    @Test("Watchdog force-finishes with the last partial when no final arrives")
    func watchdogRecoversStuckStop() async {
        let session = FakeDictationSession()
        let sink = RecordingSink()
        let controller = makeController(session: session, sink: sink, finalizeTimeout: .milliseconds(40))

        controller.toggle()
        #expect(await waitForPhase(controller, .listening))
        session.emit(.partial("kept words"))
        await Task.yield()
        controller.toggle()
        #expect(controller.phase == .stopping)

        try? await Task.sleep(for: .milliseconds(150))
        #expect(sink.inserted == ["kept words"])
        #expect(controller.phase == .idle)
        #expect(session.cancelCallCount >= 1)
    }

    @Test("Denied permissions mark the controller unavailable")
    func deniedPermissionIsUnavailable() {
        let session = FakeDictationSession()
        let sink = RecordingSink()
        let controller = makeController(session: session, sink: sink, outcome: .denied)

        controller.toggle()
        #expect(controller.phase == .unavailable)
        #expect(session.finishCallCount == 0)
    }

    @Test("Undetermined permissions request; grant proceeds to listening")
    func undeterminedRequestsAndStarts() async {
        let session = FakeDictationSession()
        let sink = RecordingSink()
        let controller = makeController(session: session, sink: sink, outcome: .undetermined)

        controller.toggle()
        #expect(controller.phase == .requestingPermission)
        #expect(await waitForPhase(controller, .listening))
    }

    @Test("Empty final transcripts do not insert")
    func emptyFinalDoesNotInsert() async {
        let session = FakeDictationSession()
        let sink = RecordingSink()
        let controller = makeController(session: session, sink: sink)

        controller.toggle()
        #expect(await waitForPhase(controller, .listening))
        session.emit(.partial("spoken"))
        await Task.yield()
        session.emit(.final("   "))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(sink.inserted.isEmpty)
        #expect(controller.phase == .idle)
    }
}
