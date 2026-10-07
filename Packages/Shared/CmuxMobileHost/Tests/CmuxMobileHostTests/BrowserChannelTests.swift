import CmuxBrowserStream
import CmuxLink
import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import Foundation
import Testing

@Suite("Browser channels over loopback (lane C2)")
struct BrowserChannelTests {
    static let screen = RbScreenInfo(cssWidth: 393, cssHeight: 852, scale: 3, refreshHz: 120)

    struct Fixture {
        let harness: PhoneHarness
        let pages: FakeBrowserPages
        let client: BrowserStreamClient
        let link: MobileLinkClient

        var attachment: FakeBrowserAttachment { pages.attachment }
        var source: FakeVideoSource { pages.attachment.source }

        func shutdown() async {
            await client.close()
            await link.close()
            await harness.shutdown()
        }
    }

    static func fixture(tab: String = "tab_b1", lane: Bool = false) async throws -> Fixture {
        let pages = FakeBrowserPages()
        let harness = try await PhoneHarness(handlers: MobileChannelHandlers(channels: [.browser: BrowserChannelHandler(pages: pages)]))
        let link = harness.linkClient()
        let client = BrowserStreamClient(client: link, params: BrowserChannelParams(tab: tab, screen: screen, datagramLane: lane))
        return Fixture(harness: harness, pages: pages, client: client, link: link)
    }

    static func nextFrame(_ iterator: inout AsyncStream<BrowserVideoFrame>.Iterator) async throws -> BrowserVideoFrame {
        nonisolated(unsafe) var it = iterator
        let frame = try await within { await it.next() }
        iterator = it
        guard let frame else { throw TimeoutError() }
        return frame
    }

    static func waitFor(_ events: AsyncStream<BrowserStreamEvent>, _ match: @escaping @Sendable (BrowserStreamEvent) -> Bool) async throws {
        _ = try await within {
            for await event in events where match(event) { return true }
            return false
        }
    }

    @Test func framesFlowInOrderWithTheirReferences() async throws {
        let f = try await Self.fixture()
        defer { Task { await f.shutdown() } }
        let opened = try await f.client.open()
        // 1440 pt page at 2x, phone 393 pt at 3x: width 1179, height 1179*900/1440 floored to even.
        #expect(opened.width == 1178)
        #expect(opened.height == 736)
        #expect(opened.caps.contains("navigate"))
        var frames = f.client.frames.makeAsyncIterator()
        // The host asks for a keyframe of the current page as soon as it opens.
        let first = try await Self.nextFrame(&frames)
        #expect(first.frame == 1)
        #expect(first.isKeyframe)
        #expect(first.refFrame == RdFrameBody.refNone)
        await f.source.push(Data("a".utf8))
        await f.source.push(Data("b".utf8))
        await f.source.push(Data("c".utf8))
        var got: [BrowserVideoFrame] = []
        for _ in 0..<3 { got.append(try await Self.nextFrame(&frames)) }
        #expect(got.map(\.frame) == [2, 3, 4])
        #expect(got.map(\.refFrame) == [1, 2, 3])
        #expect(got.allSatisfy { !$0.isKeyframe })
        #expect(got.map { Data($0.accessUnit.dropFirst()) } == [Data("a".utf8), Data("b".utf8), Data("c".utf8)])
        try await Self.waitFor(f.client.events) { if case .page(let page) = $0 { page.title == "Example" } else { false } }
    }

    @Test func videoMovesToTheDatagramLaneAndARecoveryRequestBringsAKeyframe() async throws {
        let f = try await Self.fixture(lane: true)
        defer { Task { await f.shutdown() } }
        try await f.client.open()
        var frames = f.client.frames.makeAsyncIterator()
        let log = EventLog()
        await log.start(f.client.events)
        _ = try await Self.nextFrame(&frames)
        // P-frames until video demonstrably rides the lane (the client logs
        // that before it delivers the frame).
        var pushed = 0
        while await !log.contains(.datagramLane(active: true)) {
            pushed += 1
            #expect(pushed < 20)
            if pushed >= 20 { return }
            await f.source.push(Data("p\(pushed)".utf8))
            _ = try await Self.nextFrame(&frames)
        }
        let requestsBefore = await f.source.keyframeRequests
        await f.client.requestRecovery()
        try await within { await f.source.waitForKeyframeRequests(requestsBefore + 1) }
        let next = try await Self.nextFrame(&frames)
        #expect(next.isKeyframe)
        #expect(next.refFrame == RdFrameBody.refNone)
        #expect(next.accessUnit.first == 0x65)
    }

    @Test func inputReachesThePageOnceAndInOrder() async throws {
        let f = try await Self.fixture()
        defer { Task { await f.shutdown() } }
        try await f.client.open()
        var sent: [RbInputEvent] = []
        for i in 0..<40 {
            let event = RbInputEvent.pointer(kind: i % 2 == 0 ? .down : .up, x: Double(i), y: 10, button: 0, buttons: i % 2 == 0 ? 1 : 0,
                                             clickCount: 1, modifiers: [], pointerType: "touch")
            sent.append(event)
            try await f.client.send(event)
        }
        try await f.client.send(.imeCommit(text: "日本", replacement: nil))
        sent.append(.imeCommit(text: "日本", replacement: nil))
        let expected = sent
        try await within { await f.attachment.waitForInputs(expected.count) }
        #expect(await f.attachment.inputs == expected)
        try await Self.waitFor(f.client.events) { $0 == .inputApplied(UInt32(expected.count)) }
    }

    @Test func navigationRefusesEverySchemeButHTTPAndHTTPS() async throws {
        let f = try await Self.fixture()
        defer { Task { await f.shutdown() } }
        try await f.client.open()
        #expect(try await f.client.navigate(to: URL(string: "file:///etc/passwd")!) == .scheme)
        #expect(try await f.client.navigate(to: URL(string: "javascript:alert(1)")!) == .scheme)
        #expect(try await f.client.navigate(to: URL(string: "data:text/html,hi")!) == .scheme)
        #expect(try await f.client.navigate(to: URL(string: "cmux://open")!) == .scheme)
        #expect(try await f.client.navigate(to: URL(string: "https://")!) == .invalid)
        #expect(try await f.client.navigate(to: URL(string: "https://example.com/a")!) == nil)
        #expect(try await f.client.navigate(to: URL(string: "HTTP://example.com/b")!) == nil)
        #expect(await f.attachment.loads.map(\.absoluteString) == ["https://example.com/a", "HTTP://example.com/b"])
        try await f.client.history(.back)
        try await f.client.history(.reload)
        _ = try await f.client.navigate(to: URL(string: "https://example.com/sync")!)
        #expect(await f.attachment.histories == [.back, .reload])
    }

    @Test func unknownTabsAreRefused() async throws {
        let f = try await Self.fixture(tab: "tab_nope")
        defer { Task { await f.shutdown() } }
        await #expect(throws: BrowserStreamClientError.refused(code: "browser.tab_not_found", message: "no browser tab tab_nope on this Mac")) {
            try await f.client.open()
        }
    }

    @Test func aRevokedDeviceCanNoLongerActOnThePage() async throws {
        let f = try await Self.fixture()
        defer { Task { await f.shutdown() } }
        try await f.client.open()
        try await f.client.send(.imeCommit(text: "ok", replacement: nil))
        try await within { await f.attachment.waitForInputs(1) }
        await f.harness.store.revoke(PhoneHarness.install)
        try await Self.waitFor(f.client.events) { if case .closed = $0 { true } else { false } }
        try? await f.client.send(.imeCommit(text: "late", replacement: nil))
        let refused = try? await f.client.navigate(to: URL(string: "https://example.com")!)
        #expect(refused == nil || refused == .notAllowed)
        #expect(await f.attachment.inputs.count == 1)
        #expect(await f.attachment.loads.isEmpty)
    }

    @Test func aNewViewportResizesTheEncodeAndForcesAKeyframe() async throws {
        let f = try await Self.fixture()
        defer { Task { await f.shutdown() } }
        try await f.client.open()
        let before = await f.source.keyframeRequests
        try await f.client.setScreen(RbScreenInfo(cssWidth: 393, cssHeight: 852, scale: 6, refreshHz: 120))
        try await Self.waitFor(f.client.events) { $0 == .screenApplied(pixelWidth: 2358, pixelHeight: 1472) }
        #expect(await f.source.keyframeRequests > before)
    }

    @Test func clipboardMovesOnlyWhenAsked() async throws {
        let f = try await Self.fixture()
        defer { Task { await f.shutdown() } }
        try await f.client.open()
        try await f.client.pushClipboard("from phone")
        _ = try await f.client.navigate(to: URL(string: "https://example.com/sync")!)
        #expect(await f.attachment.pasteboards == [[.text("from phone")]])
        await f.attachment.emit(.clipboardWrite([.text("from page")]))
        try await Self.waitFor(f.client.events) { $0 == .clipboardWrite([.text("from page")]) }
    }
}
