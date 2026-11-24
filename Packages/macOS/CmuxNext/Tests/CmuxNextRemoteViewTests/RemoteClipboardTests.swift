@testable import CmuxNextRemoteView
import Foundation
import Testing

/// Screen share input, copy and paste (Leo, 2026-11-19: "did you fucking test it?"): text set on
/// either side shows on the other once the viewer carries the clipboard (cap `clipboard.text`).
@Suite struct RemoteClipboardPolicyTests {
    @Test func theSettingAndTheOwnDeviceRuleDecide() {
        #expect(RemoteClipboardPolicy.allows(.ownDevicesOnly, ownDevice: true))
        #expect(!RemoteClipboardPolicy.allows(.ownDevicesOnly, ownDevice: false))
        #expect(RemoteClipboardPolicy.allows(.always, ownDevice: false))
        #expect(!RemoteClipboardPolicy.allows(.never, ownDevice: true))
        #expect(RemoteDesktopSettings().clipboard == .ownDevicesOnly, "the default stays own devices only")
    }

    @Test func aTextTheViewerOffersArrivesAtTheHostSide() throws {
        let viewer = try #require(RemoteRdClipboard())
        let host = try #require(RemoteRdClipboard())
        #expect(try viewer.offer("héllo from the viewer"))
        let frame = try #require(viewer.popFrame(nowMicros: 1_000))
        #expect(frame.first == 1, "a stream control frame")
        #expect(host.receive(control: frame.dropFirst(5)) == "héllo from the viewer")
        #expect(try !viewer.offer("héllo from the viewer"), "the host has it: nothing queued again")
    }

    @Test func aTextOverTheBoundIsRefusedNotTruncated() throws {
        let viewer = try #require(RemoteRdClipboard())
        #expect(throws: RemoteRdClipboardError.tooLarge) {
            try viewer.offer(String(repeating: "a", count: RemoteRdClipboard.maxTextBytes + 1))
        }
        #expect(viewer.popFrame(nowMicros: 1_000) == nil)
        #expect(viewer.dropped == 1)
    }

    @Test func aHelloOnlyListsTheCapWhenTheCallerAsked() throws {
        let hello = RemoteRdHello(user: "viewer", install: "t", token: nil, caps: ["cursor"])
        let with = try #require(RemoteRdStreamTransport(carrier: NullCarrier(), hello: hello, startKey: "k", clipboard: true))
        let without = try #require(RemoteRdStreamTransport(carrier: NullCarrier(), hello: hello, startKey: "k"))
        #expect(with.hello.caps == ["cursor", RemoteRdHello.clipboardTextCap])
        #expect(without.hello.caps == ["cursor"])
    }
}

private final class NullCarrier: RemoteRdByteCarrier, @unchecked Sendable {
    // unchecked-allow: stateless test fake
    func start(queue: DispatchQueue, events: @escaping @Sendable (RemoteRdCarrierEvent) -> Void) {}
    func send(_ bytes: Data) {}
    func cancel() {}
}

@MainActor
@Suite struct RemoteClipboardBridgeTests {
    private final class FakePasteboard: RemoteClipboardPasteboard {
        var changeCount = 1
        var current: String?
        func text() -> String? { current }
        func setText(_ text: String) -> Int {
            current = text
            changeCount += 1
            return changeCount
        }
        func copyElsewhere(_ text: String) {
            current = text
            changeCount += 1
        }
    }

    private final class FakeChannel: RemoteClipboardChannel, @unchecked Sendable {
        // unchecked-allow: test fake, touched from the main actor only
        var offered: [String] = []
        let stream: AsyncStream<String>
        let continuation: AsyncStream<String>.Continuation
        init() { (stream, continuation) = AsyncStream.makeStream(of: String.self) }
        func clipboardTexts() -> AsyncStream<String> { stream }
        func offerClipboard(_ text: String) { offered.append(text) }
    }

    @Test func aCopyWhileHoldingControlIsOfferedOnce() {
        let pasteboard = FakePasteboard()
        let channel = FakeChannel()
        let bridge = RemoteClipboardBridge(channel: channel, pasteboard: pasteboard, holdsControl: { true })
        bridge.start()
        bridge.checkNow()
        #expect(channel.offered.isEmpty, "what was on the pasteboard at the start is not a change")
        pasteboard.copyElsewhere("from the viewer Mac")
        bridge.checkNow()
        bridge.checkNow()
        #expect(channel.offered == ["from the viewer Mac"])
        bridge.stop()
    }

    @Test func aCopyWhileViewOnlyIsNeverSentLater() {
        let pasteboard = FakePasteboard()
        let channel = FakeChannel()
        var control = false
        let bridge = RemoteClipboardBridge(channel: channel, pasteboard: pasteboard, holdsControl: { control })
        bridge.start()
        pasteboard.copyElsewhere("private")
        bridge.checkNow()
        control = true
        bridge.checkNow()
        #expect(channel.offered.isEmpty)
        bridge.stop()
    }

    @Test func theHostsTextLandsOnThePasteboardAndIsNotSentBack() async {
        let pasteboard = FakePasteboard()
        let channel = FakeChannel()
        let bridge = RemoteClipboardBridge(channel: channel, pasteboard: pasteboard, holdsControl: { true })
        bridge.start()
        channel.continuation.yield("from the host")
        for _ in 0..<200 where pasteboard.current == nil { await Task.yield() }
        #expect(pasteboard.current == "from the host")
        bridge.checkNow()
        #expect(channel.offered.isEmpty)
        bridge.stop()
    }
}
