import CmuxBrowserStream
import CmuxLink
import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import CmuxRemoteDesktop
import Foundation
import Testing

@Suite("Remote desktop channels over loopback (lane C3)")
struct RemoteDesktopChannelTests {
    static let screen = DesktopScreen(pixelWidth: 1179, pixelHeight: 2556, scale: 3)

    struct Fixture {
        let harness: PhoneHarness
        let sources: FakeDesktopSources
        let consent: FakeConsent
        let indicator: FakeIndicator
        let client: RemoteDesktopClient
        let log = DesktopEventLog()

        func target(_ index: Int = 0) async throws -> FakeDesktopTarget {
            try await within { await sources.openCount.wait(atLeast: index + 1) }
            guard let target = await sources.target(index) else { throw TimeoutError() }
            return target
        }

        func handle() async throws -> FakeIndicatorHandle {
            try await within { await indicator.beginCount.wait(atLeast: 1) }
            guard let handle = await indicator.handle(0) else { throw TimeoutError() }
            return handle
        }

        func waitFor(_ match: @escaping @Sendable (RemoteDesktopEvent) -> Bool) async throws {
            try await within { await log.waitFor(match) }
        }

        func shutdown() async {
            await client.close()
            await harness.shutdown()
        }
    }

    static func fixture(target: DesktopTarget = .display(nil), mode: DesktopMode = .control, consent: Bool? = true,
                        permissions: FakePermissions = FakePermissions(), policy: RemoteDesktopPolicy = RemoteDesktopPolicy(),
                        clock: LinkClock = .continuous, lane: Bool = false) async throws -> Fixture {
        let sources = FakeDesktopSources()
        let fakeConsent = FakeConsent(answer: consent)
        let indicator = FakeIndicator()
        let handler = RemoteDesktopChannelHandler(sources: sources, permissions: permissions, consent: fakeConsent,
                                                  indicator: indicator, policy: policy, clock: clock)
        let harness = try await PhoneHarness(handlers: MobileChannelHandlers(channels: [.rd: handler]))
        try await harness.hello()
        let client = RemoteDesktopClient(opener: HarnessDesktopOpener(link: harness.phone),
                                         params: RemoteDesktopChannelParams(target: target, mode: mode, screen: screen,
                                                                            datagramLane: lane))
        let fixture = Fixture(harness: harness, sources: sources, consent: fakeConsent, indicator: indicator, client: client)
        await fixture.log.start(client.events)
        return fixture
    }

    static func nextFrame(_ client: RemoteDesktopClient, _ iterator: inout AsyncStream<RemoteDesktopFrame>.Iterator) async throws
        -> RemoteDesktopFrame {
        nonisolated(unsafe) var it = iterator
        let frame = try await within { await it.next() }
        iterator = it
        guard let frame else { throw TimeoutError() }
        return frame
    }

    @Test func framesFlowAfterConsentAndCarryTheirView() async throws {
        let f = try await Self.fixture()
        defer { Task { await f.shutdown() } }
        let opened = try await f.client.open()
        #expect(opened.target == DesktopTargetInfo(kind: .display, width: 3024, height: 1964, scale: 2, name: "Built-in"))
        #expect(opened.view == DesktopView(seq: 0, rect: DesktopRect(width: 3024, height: 1964), pixelWidth: 1178, pixelHeight: 764))
        #expect(opened.displays.map(\.id) == [1, 2])
        #expect(opened.mode == .control)
        #expect(opened.cursor == .local)
        #expect(Set(opened.caps) == ["view", "clipboard", "displays", "windows"])
        var frames = f.client.frames.makeAsyncIterator()
        let first = try await Self.nextFrame(f.client, &frames)
        #expect(first.isKeyframe)
        #expect(first.view == opened.view)
        let target = try await f.target()
        await target.source.push(Data("p".utf8))
        let second = try await Self.nextFrame(f.client, &frames)
        #expect(second.refFrame == first.frame)
        try await f.waitFor { $0 == .state(.live, reason: nil) }
        #expect(await f.log.events.first == .state(.waitingConsent, reason: nil))
        let consented = await f.consent.requests
        #expect(consented.map(\.mode) == [.control])
        #expect(consented.first?.install == PhoneHarness.install)
        let sessions = await f.indicator.sessions
        #expect(sessions.map(\.mode) == [.control])
        #expect(await f.sources.opens.first?.region == opened.view.rect)
    }

    @Test func aDeniedConsentEndsTheSessionBeforeAnyCapture() async throws {
        let f = try await Self.fixture(consent: false)
        defer { Task { await f.shutdown() } }
        try await f.client.open()
        try await f.waitFor { if case .closed = $0 { true } else { false } }
        let events = await f.log.events
        #expect(events.contains(.ended(reason: "consent_denied")))
        #expect(events.last == .closed(reason: "rd.consent_denied"))
        #expect(await f.sources.opens.isEmpty)
        #expect(await f.indicator.sessions.isEmpty)
    }

    @Test func anUnansweredConsentTimesOutAsADenial() async throws {
        let clock = ManualClock()
        let f = try await Self.fixture(consent: nil, clock: LinkClock(clock))
        defer { Task { await f.shutdown() } }
        try await f.client.open()
        try await f.waitFor { $0 == .state(.waitingConsent, reason: nil) }
        try await within {
            while clock.sleeperCount == 0 { await Task.yield() }
        }
        clock.advance(by: .seconds(30))
        try await f.waitFor { $0 == .ended(reason: "consent_denied") }
        #expect(await f.sources.opens.isEmpty)
        try await within { while await f.consent.cancelled == 0 { await Task.yield() } }
    }

    @Test func withoutScreenRecordingTheChannelIsRefusedAndNobodyIsAsked() async throws {
        let f = try await Self.fixture(permissions: FakePermissions(screenRecording: false))
        defer { Task { await f.shutdown() } }
        await #expect(throws: RemoteDesktopClientError.refused(code: "rd.permission_denied",
                                                              message: "Screen Recording is off for cmux on this Mac")) {
            try await f.client.open()
        }
        #expect(await f.consent.requests.isEmpty)
    }

    @Test func withoutAccessibilityTheSessionIsViewOnlyAndInputNeverReachesTheTarget() async throws {
        let f = try await Self.fixture(permissions: FakePermissions(accessibility: false))
        defer { Task { await f.shutdown() } }
        let opened = try await f.client.open()
        #expect(opened.mode == .view)
        try await f.waitFor { $0 == .modeApplied(mode: .view, reason: "accessibility") }
        let target = try await f.target()
        try await f.waitFor { $0 == .state(.live, reason: nil) }
        try await f.client.send([.pointer(x: 10, y: 10), .button(button: 1, down: true), .button(button: 1, down: false)])
        try await f.waitFor { $0 == .inputApplied(3) }
        #expect(await target.inputs.isEmpty)
        try await f.client.setMode(.control)
        try await within {
            while await f.log.events.filter({ $0 == .modeApplied(mode: .view, reason: "accessibility") }).count < 2 {
                await f.log.count.wait(atLeast: await f.log.events.count + 1)
            }
        }
        #expect(await target.inputs.isEmpty)
    }

    @Test func controlInputReachesTheTargetUntilTheDeviceIsRevoked() async throws {
        let f = try await Self.fixture()
        defer { Task { await f.shutdown() } }
        try await f.client.open()
        let target = try await f.target()
        try await f.waitFor { $0 == .state(.live, reason: nil) }
        let events: [RdInputEvent] = [.pointer(x: 100, y: 200), .button(button: 1, down: true), .button(button: 1, down: false),
                                      .key(usage: HidUsage.leftCommand.rawValue, down: true), .text("日本"),
                                      .scroll(dx: 0, dy: 300, precise: true)]
        try await f.client.send(events)
        try await within { await target.inputCount.wait(atLeast: events.count) }
        #expect(await target.inputs == events)
        await f.harness.store.revoke(PhoneHarness.install)
        try await f.waitFor { if case .closed = $0 { true } else { false } }
        try? await f.client.send([.pointer(x: 1, y: 1)])
        try await within { while await !target.closed { await Task.yield() } }
        #expect(await target.inputs.count == events.count)
        let handle = try await f.handle()
        #expect(await handle.state.ended)
    }

    @Test func stopOnTheMacEndsTheSessionAndNoFrameFollows() async throws {
        let f = try await Self.fixture()
        defer { Task { await f.shutdown() } }
        try await f.client.open()
        var frames = f.client.frames.makeAsyncIterator()
        _ = try await Self.nextFrame(f.client, &frames)
        let handle = try await f.handle()
        let target = try await f.target()
        handle.pressStop()
        try await f.waitFor { if case .closed = $0 { true } else { false } }
        let events = await f.log.events
        #expect(events.contains(.ended(reason: "stopped_by_host")))
        #expect(events.last == .closed(reason: "rd.stopped_by_host"))
        await target.source.push(Data("late".utf8))
        nonisolated(unsafe) var it = frames
        let after = try await within { await it.next() }
        #expect(after == nil)
        #expect(await target.closed)
    }

    @Test func aViewRequestIsClampedCropsTheTargetAndLabelsLaterFrames() async throws {
        let f = try await Self.fixture()
        defer { Task { await f.shutdown() } }
        try await f.client.open()
        var frames = f.client.frames.makeAsyncIterator()
        _ = try await Self.nextFrame(f.client, &frames)
        let target = try await f.target()
        let seq = try await f.client.requestView(DesktopRect(x: 2900, y: 100, width: 600, height: 1300), pixelWidth: 1179,
                                                 pixelHeight: 2556)
        let applied = DesktopView(seq: seq, rect: DesktopRect(x: 2424, y: 100, width: 600, height: 1300), pixelWidth: 600,
                                  pixelHeight: 1300)
        try await f.waitFor { $0 == .viewApplied(applied) }
        #expect(await target.regions.last == applied.rect)
        #expect(await target.source.keyframeRequests >= 2)
        // A frame encoded at the old size keeps the old view; the next one
        // at the view's size carries the new view.
        var seen: [DesktopView] = []
        for round in 0..<6 where !seen.contains(applied) {
            await target.source.push(Data("v\(round)".utf8))
            seen.append(try await Self.nextFrame(f.client, &frames).view)
        }
        #expect(seen.contains(applied))
        #expect(seen.allSatisfy { $0 == applied || $0.seq == 0 })
    }

    @Test func switchingDisplaysOpensTheOtherDisplayAndAnnouncesIt() async throws {
        let f = try await Self.fixture()
        defer { Task { await f.shutdown() } }
        try await f.client.open()
        let first = try await f.target()
        try await f.waitFor { $0 == .state(.live, reason: nil) }
        try await f.client.selectDisplay(2)
        let second = try await f.target(1)
        let studio = DesktopTargetInfo(kind: .display, width: 5120, height: 2880, scale: 2, name: "Studio")
        try await f.waitFor { $0 == .target(studio) }
        try await f.waitFor {
            if case .viewApplied(let view) = $0 { view.seq > DesktopView.hostSeqBase && view.rect == studio.bounds } else { false }
        }
        #expect(await first.closed)
        #expect(await !second.closed)
        #expect(await f.sources.opens.last?.target == .display(2))
    }

    @Test func clipboardPushNeedsControlAndPullAnswersWithTheMacText() async throws {
        let f = try await Self.fixture()
        defer { Task { await f.shutdown() } }
        try await f.client.open()
        let target = try await f.target()
        try await f.waitFor { $0 == .state(.live, reason: nil) }
        try await f.client.pushClipboard("make test")
        try await within { await target.pushCount.wait(atLeast: 1) }
        #expect(await target.pushed == ["make test"])
        try await f.client.pullClipboard()
        try await f.waitFor { $0 == .clipboard("mac text") }
    }

    @Test func theMacRefusesVncWhenItsPolicyIsOffAndUnknownTargets() async throws {
        let off = try await Self.fixture(target: .vnc(try VncAddress(host: "10.0.0.5")), policy: RemoteDesktopPolicy(vnc: .off))
        defer { Task { await off.shutdown() } }
        await #expect(throws: RemoteDesktopClientError.self) { try await off.client.open() }
        let window = try await Self.fixture(target: .window(9))
        defer { Task { await window.shutdown() } }
        do {
            try await window.client.open()
            Issue.record("a missing window opened")
        } catch RemoteDesktopClientError.refused(let code, _) {
            #expect(code == "rd.window_not_found")
        }
        let loopback = try await Self.fixture(target: .vnc(try VncAddress(host: "127.0.0.1")),
                                              policy: RemoteDesktopPolicy(vnc: .allowed(allowLoopback: false)))
        defer { Task { await loopback.shutdown() } }
        do {
            try await loopback.client.open()
            Issue.record("a loopback VNC target opened")
        } catch RemoteDesktopClientError.refused(let code, _) {
            #expect(code == "rd.vnc_not_allowed")
        }
    }

    @Test func videoMovesToTheDatagramLane() async throws {
        let f = try await Self.fixture(lane: true)
        defer { Task { await f.shutdown() } }
        try await f.client.open()
        var frames = f.client.frames.makeAsyncIterator()
        _ = try await Self.nextFrame(f.client, &frames)
        let target = try await f.target()
        var pushed = 0
        while await !f.log.events.contains(.datagramLane(active: true)) {
            pushed += 1
            #expect(pushed < 20)
            if pushed >= 20 { return }
            await target.source.push(Data("p\(pushed)".utf8))
            _ = try await Self.nextFrame(f.client, &frames)
        }
    }

    @Test func asTheOwnerOptedOutOfThePanelNobodyIsAskedButTheIndicatorShows() async throws {
        let f = try await Self.fixture(consent: false, policy: RemoteDesktopPolicy(consent: .indicatorOnly))
        defer { Task { await f.shutdown() } }
        try await f.client.open()
        _ = try await f.target()
        _ = try await f.handle()
        #expect(await f.consent.requests.isEmpty)
        #expect(await !f.log.events.contains(.state(.waitingConsent, reason: nil)))
    }
}
