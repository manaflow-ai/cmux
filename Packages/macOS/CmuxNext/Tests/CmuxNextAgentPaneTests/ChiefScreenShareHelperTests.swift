import CmuxNextDictation
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The cmux Computer Use helper as Share Screen sees it: each Screen Recording check and each look
/// takes the next scripted answer (the helper gone, not allowed, allowed / a frame); when the script
/// runs out, the helper runs and is allowed.
private actor ScriptedHelper: ChiefScreenCapturing {
    enum Answer: Sendable { case gone, refused, allowed }

    private var checks: [Answer]
    private var looks: [ChiefScreenCaptureInterruption?]
    private(set) var requests = 0
    private(set) var captures = 0
    private var frame = 0

    init(checks: [Answer], looks: [ChiefScreenCaptureInterruption?] = []) {
        self.checks = checks
        self.looks = looks
    }

    @concurrent nonisolated func isAllowed() async throws -> Bool { try await check() }
    @concurrent nonisolated func requestAccess() async throws -> Bool {
        await countRequest()
        return try await check()
    }
    @concurrent nonisolated func capture(changedSince previous: VoiceRoomFrameSignature?) async throws -> ChiefScreenFrame? {
        try await look()
    }

    private func countRequest() { requests += 1 }

    private func check() throws -> Bool {
        switch checks.isEmpty ? .allowed : checks.removeFirst() {
        case .gone: throw ChiefScreenCaptureInterruption.unavailable
        case .refused: return false
        case .allowed: return true
        }
    }

    private func look() throws -> ChiefScreenFrame? {
        captures += 1
        if !looks.isEmpty, let interruption = looks.removeFirst() { throw interruption }
        frame += 1
        let pixels = [UInt8](repeating: UInt8(frame * 40 % 256), count: VoiceRoomFrameSignature.width * VoiceRoomFrameSignature.height)
        guard let signature = VoiceRoomFrameSignature(pixels: pixels) else { return nil }
        return ChiefScreenFrame(signature: signature, jpeg: Data([1]), text: "frame \(frame)", app: "Safari", window: nil)
    }
}

private actor Journal: ChiefScreenJournaling {
    nonisolated let records: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private(set) var sharing = false
    private(set) var begins = 0

    init() { (records, continuation) = AsyncStream.makeStream() }

    func beginSharing() {
        sharing = true
        begins += 1
    }

    func endSharing() { sharing = false }

    func record(_ frame: ChiefScreenFrame, at: Date, remember: Bool) -> ChiefScreenObservation? {
        guard sharing else { return nil }
        continuation.yield(frame.text)
        return ChiefScreenObservation(at: at, day: "2026-10-31", time: "18:00:00", app: frame.app, window: frame.window,
                                      text: frame.text, frame: "/tmp/f.jpg")
    }
}

/// Share Screen reads the screen through the cmux Computer Use helper, so Screen Recording is the
/// helper's grant: granting it relaunches the helper ("Quit & Reopen"), never cmux. Sharing waits
/// that out and starts (or resumes) by itself, with no second click and no second prompt.
@MainActor
@Suite struct ChiefScreenShareHelperTests {
    @Test func aGrantThenTheHelperRelaunchingStartsSharingByItself() async throws {
        let clock = ManualClock()
        let journal = Journal()
        // Not allowed, the prompt (still not allowed: the person is in System Settings), then the
        // helper quits to relaunch, then it answers allowed.
        let helper = ScriptedHelper(checks: [.refused, .refused, .gone, .allowed])
        let share = ChiefScreenShare(capture: helper, journal: journal, interval: .seconds(5), clock: clock)
        var records = journal.records.makeAsyncIterator()
        share.start()
        await share.settled()
        #expect(share.state == .needsPermission)
        #expect(share.isOn, "the toggle stays on while it waits for the grant")
        #expect(!share.isReading)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        try await until { share.state == .waitingForHelper }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        #expect(await records.next() == "frame 1")
        #expect(share.state == .sharing)
        #expect(await helper.requests == 1, "macOS is asked once, for the helper")
        #expect(await journal.begins == 1)
    }

    @Test func theHelperRelaunchingMidShareResumesSharing() async throws {
        let clock = ManualClock()
        let journal = Journal()
        let helper = ScriptedHelper(checks: [.allowed, .gone, .allowed], looks: [nil, .unavailable])
        let share = ChiefScreenShare(capture: helper, journal: journal, interval: .seconds(5), clock: clock)
        var records = journal.records.makeAsyncIterator()
        share.start()
        #expect(await records.next() == "frame 1")
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        try await until { share.state == .waitingForHelper }
        for _ in 0..<2 {
            try await clock.waitForSleeper()
            clock.advance(by: .seconds(5))
        }
        #expect(await records.next() == "frame 2")
        #expect(share.state == .sharing)
        #expect(await journal.begins == 1)
        #expect(await journal.sharing)
    }

    @Test func screenRecordingTakenBackWaitsForItAgain() async throws {
        let clock = ManualClock()
        let journal = Journal()
        let helper = ScriptedHelper(checks: [.allowed, .refused, .refused], looks: [nil, .notAllowed])
        let share = ChiefScreenShare(capture: helper, journal: journal, interval: .seconds(5), clock: clock)
        var records = journal.records.makeAsyncIterator()
        share.start()
        _ = await records.next()
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        try await until { share.state == .needsPermission }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        try await clock.waitForSleeper()
        #expect(share.state == .needsPermission)
        clock.advance(by: .seconds(5))
        #expect(await records.next() == "frame 2")
        #expect(await helper.requests == 1)
    }

    @Test func stopWhileWaitingLeavesNothingRunning() async throws {
        let clock = ManualClock()
        let helper = ScriptedHelper(checks: [.gone])
        let share = ChiefScreenShare(capture: helper, journal: Journal(), interval: .seconds(5), clock: clock)
        share.start()
        await share.settled()
        #expect(share.state == .waitingForHelper)
        try await clock.waitForSleeper()
        share.stop()
        #expect(share.state == .off)
        await #expect(throws: ManualClock.NoSleeper.self) { try await clock.waitForSleeper(within: .milliseconds(200)) }
        #expect(await helper.captures == 0)
    }

    /// Waits for a state the next timer step reaches: the step starts after the clock advances, so
    /// ``ChiefScreenShare/settled()`` cannot wait for it yet.
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
        #expect(condition())
    }
}

/// A helper socket that answers in order: a reply, "gone" or a refusal.
private final class FakeHost: ChiefScreenCaptureHost, @unchecked Sendable {
    struct Gone: Error {}
    struct Refused: Error { var text: String }

    private let lock = NSLock()
    private var answers: [Result<[String: Any], any Error>]
    private(set) var sent: [[String: Any]] = []

    init(_ answers: [Result<[String: Any], any Error>]) { self.answers = answers }

    @concurrent func screenRecordingAllowed() async throws -> Bool { try next()["screen_recording"] as? Bool ?? false }
    @concurrent func requestScreenRecording() async throws { _ = try next() }
    @concurrent func displayStill(_ arguments: [String: Any]) async throws -> [String: Any] {
        lock.withLock { sent.append(arguments) }
        return try next()
    }
    func isHelperGone(_ error: any Error) -> Bool { error is Gone }
    func refusal(_ error: any Error) -> String? { (error as? Refused)?.text }

    private func next() throws -> [String: Any] {
        try lock.withLock { answers.removeFirst() }.get()
    }
}

/// ``ChiefScreenHelperCapture`` turns the helper's answers into frames and interruptions.
@Suite struct ChiefScreenHelperCaptureTests {
    static let thumb = Data(repeating: 3, count: 640).base64EncodedString()

    @Test func aGoneHelperOrAMissingGrantIsAnInterruption() async throws {
        let capture = ChiefScreenHelperCapture(host: FakeHost([
            .failure(FakeHost.Gone()), .failure(FakeHost.Refused(text: "screen_recording_not_granted")),
            .failure(FakeHost.Refused(text: "Unknown method")), .failure(FakeHost.Gone()),
        ]))
        await #expect(throws: ChiefScreenCaptureInterruption.unavailable) { _ = try await capture.capture(changedSince: nil) }
        await #expect(throws: ChiefScreenCaptureInterruption.notAllowed) { _ = try await capture.capture(changedSince: nil) }
        await #expect(throws: FakeHost.Refused.self) { _ = try await capture.capture(changedSince: nil) }
        await #expect(throws: ChiefScreenCaptureInterruption.unavailable) { _ = try await capture.isAllowed() }
    }

    @Test func anUnchangedScreenIsNoFrameAndAskingAsksTheHelper() async throws {
        let host = FakeHost([.success(["signature": Self.thumb, "changed": false]), .success([:]),
                             .success(["screen_recording": true])])
        let capture = ChiefScreenHelperCapture(host: host)
        let previous = try #require(VoiceRoomFrameSignature(pixels: [UInt8](repeating: 3, count: 640)))
        #expect(try await capture.capture(changedSince: previous) == nil)
        #expect(host.sent.first?["previous_signature"] as? String == Self.thumb)
        #expect(try await capture.requestAccess())
    }
}

/// The helper's `display_still` request and reply (scripts/cmux-cua-display-still.patch).
@Suite struct ChiefScreenStillWireTests {
    @Test func argumentsNameTheExcludedAppsAndTheLastThumbnail() throws {
        let previous = try #require(VoiceRoomFrameSignature(pixels: [UInt8](repeating: 7, count: 640)))
        let exclusions = ChiefScreenShareExclusions(bundleIDs: ["com.1password.1password", "com.apple.Passwords"], ownProcess: 10)
        let args = ChiefScreenStillWire.arguments(ChiefScreenStillRequest(width: 1440, exclusions: exclusions, previous: previous,
                                                                          threshold: 0.02, quality: 60))
        #expect(args["width"] as? Int == 1440)
        #expect(args["exclude_pids"] as? [Int] == [10])
        #expect(args["exclude_bundle_ids"] as? [String] == ["com.1password.1password", "com.apple.Passwords"])
        #expect(args["exclude_bundle_prefixes"] as? [String] == ["com.cmuxterm."], "every cmux build")
        #expect(args["quality"] as? Int == 60)
        let signature = try #require(args["previous_signature"] as? String)
        #expect(Data(base64Encoded: signature) == Data(repeating: 7, count: 640))
        #expect(ChiefScreenStillWire.arguments(ChiefScreenStillRequest(width: 1440, exclusions: exclusions, previous: nil,
                                                                       threshold: 0.02, quality: 60))["previous_signature"] == nil)
    }

    @Test func aReplyBecomesAStill() throws {
        let thumb = Data(repeating: 3, count: 640).base64EncodedString()
        let changed = try #require(ChiefScreenStillWire.still(["signature": thumb, "changed": true, "jpeg": Data([0xFF, 0xD8]).base64EncodedString(),
                                                               "width": 1440, "height": 900, "front_app": "Safari", "front_window": ""]))
        #expect(changed.jpeg == Data([0xFF, 0xD8]))
        #expect(changed.app == "Safari")
        #expect(changed.window == nil)
        let same = try #require(ChiefScreenStillWire.still(["signature": thumb, "changed": false]))
        #expect(same.jpeg == nil)
        #expect(ChiefScreenStillWire.still(["signature": "AAAA", "changed": false]) == nil)
        #expect(ChiefScreenStillWire.still(["signature": thumb, "changed": true]) == nil)
        #expect(ChiefScreenStillWire.interruption(refusal: "screen_recording_not_granted") == .notAllowed)
        #expect(ChiefScreenStillWire.interruption(refusal: "Unknown method") == nil)
    }

    /// cmux.app never reads the screen or asks for Screen Recording for Share Screen: only the helper
    /// does, so a grant relaunches the helper, never cmux.
    @Test func shareScreenNeverCapturesInTheApp() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        let folders = ["CmuxNextDictation/ChiefScreenShare", "CmuxNextAgentPane/ChiefScreenShare"]
        let host = "CmuxNextComputerUse/ComputerUseScreenStills.swift"
        let banned = ["ScreenCaptureKit", "SCScreenshotManager", "SCShareableContent", "CGRequestScreenCaptureAccess",
                      "CGPreflightScreenCaptureAccess", "CGWindowListCopyWindowInfo", "CGWindowListCreateImage"]
        var checked = 0
        for folder in folders {
            let dir = sources.appending(path: folder)
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) where name.hasSuffix(".swift") {
                let text = try String(contentsOf: dir.appending(path: name), encoding: .utf8)
                checked += 1
                for word in banned { #expect(!text.contains(word), "\(folder)/\(name) uses \(word)") }
            }
        }
        #expect(checked >= 10)
        let hostText = try String(contentsOf: sources.appending(path: host), encoding: .utf8)
        for word in banned + ["runningApplications"] { #expect(!hostText.contains(word), "\(host) uses \(word)") }
        let services = try String(contentsOf: sources.appending(path: "CmuxNextApp/AppServices.swift"), encoding: .utf8)
        #expect(services.contains("ChiefScreenHelperCapture(host: ComputerUseScreenStills(helper: .shared))"))
    }
}
