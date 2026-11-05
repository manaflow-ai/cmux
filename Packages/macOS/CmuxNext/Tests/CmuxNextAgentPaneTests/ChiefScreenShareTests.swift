import CmuxNextDictation
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A screen that answers the frames it is given, in order; nil is "looks the same".
private actor FakeScreen: ChiefScreenCapturing {
    private var frames: [ChiefScreenFrame?]
    private var allowed: Bool
    private let grantsOnRequest: Bool
    private(set) var captures = 0
    private(set) var requests = 0

    init(_ texts: [String?], allowed: Bool = true, grantsOnRequest: Bool = false) {
        frames = texts.map { $0.flatMap(FakeScreen.frame) }
        self.allowed = allowed
        self.grantsOnRequest = grantsOnRequest
    }

    static func frame(_ text: String) -> ChiefScreenFrame? {
        let pixels = [UInt8](repeating: UInt8(truncatingIfNeeded: text.utf8.reduce(0) { $0 &+ Int($1) }),
                             count: VoiceRoomFrameSignature.width * VoiceRoomFrameSignature.height)
        guard let signature = VoiceRoomFrameSignature(pixels: pixels) else { return nil }
        return ChiefScreenFrame(signature: signature, jpeg: Data(text.utf8), text: text, app: "Safari", window: "Docs")
    }

    @concurrent nonisolated func isAllowed() async -> Bool { await allowedNow() }
    @concurrent nonisolated func requestAccess() async -> Bool { await request() }
    @concurrent nonisolated func capture(changedSince previous: VoiceRoomFrameSignature?) async throws -> ChiefScreenFrame? {
        await next(forced: previous == nil)
    }

    private func allowedNow() -> Bool { allowed }

    private func request() -> Bool {
        requests += 1
        if grantsOnRequest { allowed = true }
        return allowed
    }

    private func next(forced: Bool) -> ChiefScreenFrame? {
        captures += 1
        guard !frames.isEmpty else { return forced ? FakeScreen.frame("same") : nil }
        return frames.removeFirst() ?? (forced ? FakeScreen.frame("same") : nil)
    }
}

/// Records what the session writes, and hands each record to the test in order.
private actor FakeJournal: ChiefScreenJournaling {
    nonisolated let records: AsyncStream<(String, Bool)>
    private let continuation: AsyncStream<(String, Bool)>.Continuation
    private(set) var sharing = false
    private(set) var ends = 0

    init() {
        (records, continuation) = AsyncStream.makeStream()
    }

    func beginSharing() { sharing = true }

    func endSharing() {
        sharing = false
        ends += 1
    }

    func record(_ frame: ChiefScreenFrame, at: Date, remember: Bool) -> ChiefScreenObservation? {
        guard sharing else { return nil }
        continuation.yield((frame.text, remember))
        return ChiefScreenObservation(at: at, day: "2026-10-30", time: "17:42:05", app: frame.app, window: frame.window,
                                      text: frame.text, frame: "/tmp/frame.jpg")
    }
}

@MainActor
@Suite struct ChiefScreenShareTests {
    @Test func startLooksAtOnceThenOnlyKeepsChangedFrames() async throws {
        let clock = ManualClock()
        let journal = FakeJournal()
        let share = ChiefScreenShare(capture: FakeScreen(["Inbox — 3 unread", nil, "Inbox — 3 unread", "PR #12 merged"]),
                                     journal: journal, interval: .seconds(5), clock: clock)
        var records = journal.records.makeAsyncIterator()
        share.start()
        let first = await records.next()
        #expect(first?.0 == "Inbox — 3 unread")
        #expect(first?.1 == true)
        #expect(share.state == .sharing)

        // An unchanged screen writes nothing; a changed frame with the same text is the current
        // screen but not a second memory entry; new text is remembered.
        for _ in 0..<3 {
            try await clock.waitForSleeper()
            clock.advance(by: .seconds(5))
        }
        let second = await records.next()
        #expect(second?.0 == "Inbox — 3 unread")
        #expect(second?.1 == false)
        let third = await records.next()
        #expect(third?.0 == "PR #12 merged")
        #expect(third?.1 == true)
        #expect(share.remembered == 2)
    }

    @Test func stopLeavesNothingRunningAndEndsTheJournal() async throws {
        let clock = ManualClock()
        let journal = FakeJournal()
        let screen = FakeScreen(["one"])
        let share = ChiefScreenShare(capture: screen, journal: journal, interval: .seconds(5), clock: clock)
        var records = journal.records.makeAsyncIterator()
        share.start()
        _ = await records.next()
        try await clock.waitForSleeper()
        share.stop()
        #expect(share.state == .off)
        #expect(!share.isOn)
        await #expect(throws: ManualClock.NoSleeper.self) { try await clock.waitForSleeper(within: .milliseconds(200)) }
        clock.advance(by: .seconds(60))
        #expect(await screen.captures == 1)
        await share.settled()
        #expect(await journal.ends == 2, "once at construction (a quit's leftovers), once at stop")
        #expect(await journal.sharing == false)
    }

    @Test func refusedScreenRecordingSharesNothing() async throws {
        let clock = ManualClock()
        let journal = FakeJournal()
        let screen = FakeScreen(["secret"], allowed: false)
        let share = ChiefScreenShare(capture: screen, journal: journal, interval: .seconds(5), clock: clock)
        share.start()
        #expect(share.isOn)
        await share.settled()
        #expect(share.state == .needsPermission)
        #expect(await screen.requests == 1)
        #expect(await screen.captures == 0)
        #expect(await journal.sharing == false)
    }

    @Test func grantedOnRequestStartsSharing() async throws {
        let journal = FakeJournal()
        let share = ChiefScreenShare(capture: FakeScreen(["hello"], allowed: false, grantsOnRequest: true), journal: journal,
                                     clock: ManualClock())
        var records = journal.records.makeAsyncIterator()
        share.start()
        #expect(await records.next()?.0 == "hello")
        #expect(share.state == .sharing)
    }

    @Test func lookAnswersTheScreenNowOnlyWhileSharing() async throws {
        let journal = FakeJournal()
        let share = ChiefScreenShare(capture: FakeScreen(["first"]), journal: journal, clock: ManualClock())
        await #expect(throws: ChiefScreenShareError.notSharing) { _ = try await share.look() }
        var records = journal.records.makeAsyncIterator()
        share.start()
        _ = await records.next()
        let seen = try await share.look()
        #expect(seen.text == "same")
        #expect(share.latest == seen)
        share.stop()
        await #expect(throws: ChiefScreenShareError.notSharing) { _ = try await share.look() }
    }
}
