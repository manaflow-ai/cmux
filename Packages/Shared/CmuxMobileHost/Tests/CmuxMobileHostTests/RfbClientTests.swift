import CmuxBrowserStream
import CmuxLink
import CmuxMobileHost
import CmuxRemoteDesktop
import Foundation
import Testing

@Suite("RFB client (VNC proxy, lane C3)")
struct RfbClientTests {
    @Test func vncAuthenticationMatchesTheReferenceVector() throws {
        // Computed independently: bit-reversed key 0e86ceceeef64e26, DES-ECB (LibreSSL).
        let challenge = Data((0..<16).map { UInt8($0) })
        let response = try RfbVncAuth().response(challenge: challenge, password: "password")
        #expect(response == Data([0xb8, 0x66, 0x92, 0x41, 0x25, 0xc8, 0xee, 0xbb, 0x9d, 0xeb, 0xc1, 0xdb, 0x61, 0xc5, 0x38, 0xe2]))
        // Only the first eight bytes of the password count.
        #expect(try RfbVncAuth().response(challenge: challenge, password: "password-and-more") == response)
    }

    @Test func aPeerThatIsNotRfbIsRefused() async throws {
        let server = ScriptedVncServer()
        let client = RfbClient(transport: server.transport)
        try await server.send(Array("HTTP/1.1 200".utf8))
        await #expect(throws: RfbError.notRfb) { try await client.negotiateVersion() }
    }

    @Test func versionsAreNegotiatedDown() async throws {
        for (banner, answer) in [("RFB 003.003\n", "RFB 003.003\n"), ("RFB 003.007\n", "RFB 003.007\n"),
                                 ("RFB 003.889\n", "RFB 003.008\n")] {
            let server = ScriptedVncServer()
            let client = RfbClient(transport: server.transport)
            try await server.send(Array(banner.utf8))
            try await client.negotiateVersion()
            #expect(try await server.read(12) == Array(answer.utf8))
        }
    }

    @Test func vncAuthenticationAsksForThePasswordOnlyWhenNeeded() async throws {
        let server = ScriptedVncServer()
        let client = RfbClient(transport: server.transport)
        try await server.send(Array("RFB 003.008\n".utf8))
        try await client.negotiateVersion()
        _ = try await server.read(12)
        try await server.send([2, 30, 2])
        let auth = Task { try await client.authenticate { "password" } }
        #expect(try await server.read(1) == [2])
        try await server.send(Data((0..<16).map { UInt8($0) }))
        let response = try await server.read(16)
        #expect(response.first == 0xb8)
        try await server.send(ScriptedVncServer.be32(0))
        try await auth.value
    }

    @Test func aWrongPasswordFailsWithTheServersReason() async throws {
        let server = ScriptedVncServer()
        let client = RfbClient(transport: server.transport)
        try await server.send(Array("RFB 003.008\n".utf8))
        try await client.negotiateVersion()
        _ = try await server.read(12)
        try await server.send([1, 2])
        let auth = Task { try await client.authenticate { "nope" } }
        _ = try await server.read(1)
        try await server.send(Data(count: 16))
        _ = try await server.read(16)
        try await server.send(ScriptedVncServer.join(ScriptedVncServer.be32(1), ScriptedVncServer.be32(8), Array("bad pass".utf8)))
        await #expect(throws: RfbError.authFailed("bad pass")) { try await auth.value }
    }

    @Test func onlyAppleAuthenticationIsUnsupported() async throws {
        let server = ScriptedVncServer()
        let client = RfbClient(transport: server.transport)
        try await server.send(Array("RFB 003.008\n".utf8))
        try await client.negotiateVersion()
        _ = try await server.read(12)
        try await server.send([1, 30])
        await #expect(throws: RfbError.authUnsupported([30])) { try await client.authenticate { nil } }
    }

    @Test func rawCopyRectAndDesktopSizeUpdateTheFramebuffer() async throws {
        let server = ScriptedVncServer()
        let client = RfbClient(transport: server.transport)
        let handshake = Task { try await server.handshake(width: 4, height: 4) }
        try await client.negotiateVersion()
        try await client.authenticate { nil }
        let initial = try await client.initialize()
        try await handshake.value
        #expect(initial == RfbServerInit(width: 4, height: 4, name: "vm"))
        var framebuffer = RfbFramebuffer(width: 4, height: 4)

        try await server.raw(x: 0, y: 0, width: 2, height: 2, bgra: [1, 2, 3, 0])
        guard case .update(let rects) = try await client.readMessage() else { throw TimeoutError() }
        for rect in rects { framebuffer.apply(rect) }
        #expect(Array(framebuffer.pixels[0..<4]) == [1, 2, 3, 0])
        #expect(Array(framebuffer.pixels[(1 * 4 + 1) * 4..<(1 * 4 + 1) * 4 + 4]) == [1, 2, 3, 0])

        // CopyRect the 2x2 block to (2, 2).
        typealias S = ScriptedVncServer
        try await server.send(S.join([0, 0], S.be16(1), S.be16(2), S.be16(2), S.be16(2), S.be16(2), S.be32(1), S.be16(0), S.be16(0)))
        guard case .update(let copies) = try await client.readMessage() else { throw TimeoutError() }
        for rect in copies { framebuffer.apply(rect) }
        #expect(Array(framebuffer.pixels[(3 * 4 + 3) * 4..<(3 * 4 + 3) * 4 + 4]) == [1, 2, 3, 0])

        // DesktopSize to 8x2.
        try await server.send(S.join([0, 0], S.be16(1), [0, 0, 0, 0], S.be16(8), S.be16(2), S.be32(-223 & 0xffff_ffff)))
        guard case .update(let sizes) = try await client.readMessage() else { throw TimeoutError() }
        for rect in sizes { framebuffer.apply(rect) }
        #expect(framebuffer.width == 8)
        #expect(framebuffer.height == 2)

        // ServerCutText.
        try await server.send(S.join([3, 0, 0, 0], S.be32(3), [0x63, 0x61, 0xE9]))
        #expect(try await client.readMessage() == .cutText("caé"))
    }

    @Test func clientMessagesFollowRfc6143() async throws {
        let server = ScriptedVncServer()
        let client = RfbClient(transport: server.transport)
        let handshake = Task { try await server.handshake(width: 100, height: 50) }
        try await client.negotiateVersion()
        try await client.authenticate { nil }
        _ = try await client.initialize()
        try await handshake.value
        try await client.key(0xFF0D, down: true)
        #expect(try await server.read(8) == [4, 1, 0, 0, 0, 0, 0xFF, 0x0D])
        try await client.pointer(mask: 0b101, x: 500, y: 7)
        #expect(try await server.read(6) == [5, 5, 0, 99, 0, 7])
        try await client.cutText("hi日")
        #expect(try await server.read(10) == [6, 0, 0, 0, 0, 0, 0, 2, 0x68, 0x69])
    }

    @Test func aVncTargetStreamsTheServersPixelsAndMapsInput() async throws {
        let server = ScriptedVncServer()
        let encoder = RecordingEncoder()
        let connector = VncDesktopConnector(dial: { _ in server.transport }, makeEncoder: { encoder })
        let address = try VncAddress(host: "10.0.0.9", name: "build-vm")
        let serving = Task {
            try await server.send(Array("RFB 003.008\n".utf8))
            _ = try await server.read(12)
            try await server.send([1, 2])
            _ = try await server.read(1)
            try await server.send(Data(count: 16))
            _ = try await server.read(16)
            try await server.send(ScriptedVncServer.be32(0))
            #expect(try await server.read(1) == [1])
            typealias S = ScriptedVncServer
            try await server.send(S.join(S.be16(64), S.be16(32), [UInt8](repeating: 0, count: 16), S.be32(2), Array("vm".utf8)))
            _ = try await server.read(20)
            _ = try await server.read(4 + 12)
            _ = try await server.read(10)
        }
        let target = try await connector.open(RemoteDesktopOpenRequest(target: .vnc(address), install: "in_x",
                                                                      region: DesktopRect(width: 0, height: 0)))
        var events = await target.events().makeAsyncIterator()
        nonisolated(unsafe) var it = events
        #expect(try await within { await it.next() } == .authRequired)
        await target.authenticate(password: "secret")
        let resized = try await within { await it.next() }
        #expect(resized == .resized(DesktopTargetInfo(kind: .vnc, width: 64, height: 32, scale: 1, name: "build-vm")))
        #expect(try await within { await it.next() } == .live)
        events = it
        try await serving.value

        try await server.raw(x: 0, y: 0, width: 64, height: 32, bgra: [9, 9, 9, 0])
        let frame = try await within {
            try await target.video.nextFrame(BrowserFrameRequest(pixelWidth: 32, pixelHeight: 16, bitrate: 1_000_000, maxFPS: 30))
        }
        #expect(frame?.pixelWidth == 32)
        #expect(frame?.pixelHeight == 16)
        _ = try await server.read(10)

        await target.apply(.pointer(x: 10, y: 20))
        let moved = try await server.read(6)
        #expect(moved == [5, 0, 0, 10, 0, 20], "\(moved)")
        await target.apply(.button(button: 3, down: true))
        #expect(try await server.read(6) == [5, 4, 0, 10, 0, 20])
        await target.apply(.scroll(dx: 0, dy: -100, precise: false))
        let wheel: [UInt8] = [5, 12, 0, 10, 0, 20, 5, 4, 0, 10, 0, 20]
        #expect(try await server.read(12) == wheel)
        await target.apply(.key(usage: HidUsage.returnKey.rawValue, down: true))
        #expect(try await server.read(8) == [4, 1, 0, 0, 0, 0, 0xFF, 0x0D])
        await target.close()
        // Close lifts the held key and button.
        #expect(try await server.read(8) == [4, 0, 0, 0, 0, 0, 0xFF, 0x0D])
        #expect(try await server.read(6) == [5, 0, 0, 10, 0, 20])
    }

    @Test func aSilentPeerTimesOutAsUnreachable() async throws {
        let server = ScriptedVncServer()
        let clock = ManualClockBox()
        let connector = VncDesktopConnector(dial: { _ in server.transport }, makeEncoder: { RecordingEncoder() },
                                            bannerTimeout: .seconds(10), clock: clock.link)
        let opening = Task {
            try await connector.open(RemoteDesktopOpenRequest(target: .vnc(try VncAddress(host: "10.0.0.9")), install: "in_x",
                                                              region: DesktopRect(width: 0, height: 0)))
        }
        try await within { while clock.clock.sleeperCount == 0 { await Task.yield() } }
        clock.clock.advance(by: .seconds(10))
        do {
            _ = try await within { try await opening.value }
            Issue.record("a silent peer opened")
        } catch let error as RemoteDesktopSourceError {
            #expect(error.code == "rd.vnc_unreachable")
        }
    }
}
