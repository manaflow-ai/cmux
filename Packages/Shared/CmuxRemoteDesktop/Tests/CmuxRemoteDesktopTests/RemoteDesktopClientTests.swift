import CmuxBrowserStream
import CmuxLink
import CmuxMobileLink
import CmuxMobileWire
import CmuxRemoteDesktop
import Foundation
import Testing

@Suite("RemoteDesktopClient against a scripted Mac")
struct RemoteDesktopClientTests {
    static let screen = DesktopScreen(pixelWidth: 1179, pixelHeight: 2556, scale: 3)
    static let params = RemoteDesktopChannelParams(target: .display(nil), mode: .control, screen: screen, datagramLane: false)
    static let target = DesktopTargetInfo(kind: .display, width: 3024, height: 1964, scale: 2, name: "Built-in")
    static let firstView = DesktopView(seq: 0, rect: DesktopRect(width: 3024, height: 1964), pixelWidth: 1178, pixelHeight: 764)

    static func open(_ mac: ScriptedMac, _ client: RemoteDesktopClient) async throws -> MobileChannel {
        async let opened = client.open()
        let channel = try await mac.acceptReliable()
        guard case .json(let value) = try await ScriptedMac.next(channel),
              case .channelOpen(let open)? = try? MobileFrame(value: value) else { throw TimeoutError() }
        #expect(open.kind == .rd)
        #expect(try RemoteDesktopChannelParams(params: open.params) == params)
        let ok = RemoteDesktopChannelOpened(datagramChannel: 7, target: target, view: firstView, displays: [], mode: .control,
                                            cursor: .local, caps: ["view"])
        try await channel.send(frame: .channelOpened(ChannelOpenedFrame(channel: 7, window: 1 << 20, params: ok.params, resumed: false)))
        #expect(try await opened == ok)
        return channel
    }

    static func sendFrame(_ channel: MobileChannel, _ packetizer: inout RdPacketizer, number: UInt32, ref: UInt32, byte: UInt8) async throws {
        let body = RdFrameBody(captureMicros: 0, refFrame: ref, accessUnit: Data([byte]))
        for datagram in try packetizer.packetize(frame: number, flags: ref == RdFrameBody.refNone ? .keyframe : [], body: body) {
            try await channel.send(binary: DesktopPayload.encodedDatagram(datagram))
        }
    }

    @Test func framesCarryTheirViewAndWaitForAViewStillInFlight() async throws {
        let mac = try await ScriptedMac.make()
        defer { Task { await mac.shutdown() } }
        let client = RemoteDesktopClient(opener: ScriptedOpener(link: mac.phone), params: Self.params)
        let channel = try await Self.open(mac, client)
        var frames = client.frames.makeAsyncIterator()
        var packetizer = RdPacketizer(maxDatagram: RdPacketizer.streamDatagram)
        try await Self.sendFrame(channel, &packetizer, number: 1, ref: RdFrameBody.refNone, byte: 1)
        nonisolated(unsafe) var it = frames
        let first = try await within { await it.next() }
        #expect(first?.view == Self.firstView)
        #expect(first?.isKeyframe == true)

        // A keyframe for view 1 arrives before view 1's answer: it waits.
        let zoomed = DesktopView(seq: 1, rect: DesktopRect(x: 100, y: 100, width: 600, height: 1300), pixelWidth: 600, pixelHeight: 1300)
        packetizer.stream = zoomed.stream
        try await Self.sendFrame(channel, &packetizer, number: 2, ref: RdFrameBody.refNone, byte: 2)
        try await channel.send(binary: DesktopPayload.control(.viewApplied(zoomed)).encoded())
        let second = try await within { await it.next() }
        frames = it
        #expect(second?.frame == 2)
        #expect(second?.view == zoomed)
    }

    @Test func inputGoesOutInSequenceInPacketsOfAtMost32() async throws {
        let mac = try await ScriptedMac.make()
        defer { Task { await mac.shutdown() } }
        let client = RemoteDesktopClient(opener: ScriptedOpener(link: mac.phone), params: Self.params)
        let channel = try await Self.open(mac, client)
        let events = (0..<40).map { RdInputEvent.pointer(x: Int32($0), y: 5) }
        try await client.send(events)
        try await client.send([.text("日本")])
        var got: [(UInt32, [RdInputEvent])] = []
        while got.count < 3 {
            guard case .datagram(let header, let body) = try await ScriptedMac.nextPayload(channel), header.kind == .input else { continue }
            let packet = try RdInputPacket(decoding: body)
            got.append((packet.firstSeq, packet.events))
        }
        #expect(got.map(\.0) == [1, 33, 41])
        #expect(got.map(\.1.count) == [32, 8, 1])
        #expect(got.flatMap(\.1) == events + [.text("日本")])
    }

    @Test func requestsAreDesktopControl() async throws {
        let mac = try await ScriptedMac.make()
        defer { Task { await mac.shutdown() } }
        let client = RemoteDesktopClient(opener: ScriptedOpener(link: mac.phone), params: Self.params)
        let channel = try await Self.open(mac, client)
        let seq = try await client.requestView(DesktopRect(x: 1, y: 2, width: 300, height: 400), pixelWidth: 900, pixelHeight: 1200)
        #expect(seq == 1)
        try await client.setMode(.view)
        try await client.pushClipboard("ls")
        try await client.pullClipboard()
        try await client.authenticate(password: "pw")
        var got: [DesktopMessage] = []
        while got.count < 5 {
            if case .control(let message) = try await ScriptedMac.nextPayload(channel) { got.append(message) }
        }
        #expect(got == [
            .view(DesktopView(seq: 1, rect: DesktopRect(x: 1, y: 2, width: 300, height: 400), pixelWidth: 900, pixelHeight: 1200)),
            .mode(.view), .clipboardPush(seq: 1, text: "ls"), .clipboardPull(seq: 2), .auth(password: "pw"),
        ])
    }

    @Test func endedAndClosedReachTheEvents() async throws {
        let mac = try await ScriptedMac.make()
        defer { Task { await mac.shutdown() } }
        let client = RemoteDesktopClient(opener: ScriptedOpener(link: mac.phone), params: Self.params)
        let channel = try await Self.open(mac, client)
        try await channel.send(binary: DesktopPayload.control(.ended(reason: "stopped_by_host")).encoded())
        await channel.close(code: "rd.stopped", message: "stopped")
        let events = try await within {
            var out: [RemoteDesktopEvent] = []
            for await event in client.events { out.append(event) }
            return out
        }
        #expect(events == [.ended(reason: "stopped_by_host"), .closed(reason: "rd.stopped")])
    }

    @Test func aRefusalCarriesTheMacsCode() async throws {
        let mac = try await ScriptedMac.make()
        defer { Task { await mac.shutdown() } }
        let client = RemoteDesktopClient(opener: ScriptedOpener(link: mac.phone), params: Self.params)
        let opening = Task { try await client.open() }
        let channel = try await mac.acceptReliable()
        _ = try await ScriptedMac.next(channel)
        await channel.refuse(code: "rd.permission_denied", message: "Screen Recording is off")
        await #expect(throws: RemoteDesktopClientError.refused(code: "rd.permission_denied", message: "Screen Recording is off")) {
            try await opening.value
        }
    }
}
