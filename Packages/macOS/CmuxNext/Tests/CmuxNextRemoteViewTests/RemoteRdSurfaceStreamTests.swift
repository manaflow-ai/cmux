import Foundation
import Testing
@testable import CmuxNextRemoteView

/// rb/1 popup surfaces (date and color pickers) stream on their own rd
/// streams (`rb.surface.show {stream}`): their frames must never reach the
/// page's decoder, and they reach the surface's own unit stream.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteRdSurfaceStreamTests {
    private static let welcome =
        #"{"t":"welcome","encoder":"t","width":64,"height":64,"max_datagram":1152,"carrier":"stream","service":"rb/1","caps":["input.service"]}"#

    private static func service(_ body: String) -> Data {
        FakeRdHost.frame(1, Data(#"{"t":"service","service":"rb/1","body":\#(body)}"#.utf8))
    }

    private static func keyframe(_ au: [UInt8], stream: UInt16) -> Data {
        var out = Data()
        for d in RemoteRdCoreTests.datagrams(frame: 1, keyframe: true, accessUnit: au, tCapture: 5, shardLen: 512, firstSeq: 0, stream: stream) {
            out += FakeRdHost.frame(2, d)
        }
        return out
    }

    /// The show, the popup's keyframe and the page's keyframe in one TCP
    /// write: the popup stream opens before its frames are read.
    @Test func popupFramesReachTheSurfaceStreamAndNeverThePage() async throws {
        let host = try FakeRdHost()
        defer { host.stop() }
        let port = try await host.start()
        let endpoint = try #require(RemoteRdLoopbackEndpoint(port: port))
        let transport = try #require(RemoteRdStreamTransport.remoteBrowser(endpoint: endpoint, user: "u", install: "i"))
        let pageUnits = transport.accessUnits()
        let bodies = transport.serviceMessages()
        var hostFrames = host.frames.makeAsyncIterator()
        transport.connect()
        _ = await hostFrames.next() // hello
        _ = await hostFrames.next() // start
        host.sendControl(Self.welcome)
        host.sendControl(#"{"t":"started","session":1}"#)

        let popup = RemoteRdCoreTests.annexB(0x65, 700)
        let page = RemoteRdCoreTests.annexB(0x65, 900)
        var blob = Self.service(#"{"t":"rb.surface.show","surface":7,"stream":1,"kind":"page_popup","anchor":{"x":10,"y":20,"width":120,"height":80},"width":240,"height":160}"#)
        blob += Self.keyframe(popup, stream: 1)
        blob += Self.keyframe(page, stream: 0)
        host.send(blob)

        var pageIterator = pageUnits.makeAsyncIterator()
        let first = try #require(await pageIterator.next())
        #expect([UInt8](first.data) == page)

        // The show reached the service stream; the popup's units wait for the surface.
        var bodyIterator = bodies.makeAsyncIterator()
        guard case let .object(show)? = await bodyIterator.next() else { Issue.record("no rb.surface.show"); return }
        #expect(show["t"] == .string("rb.surface.show"))
        var surfaceIterator = transport.surfaceAccessUnits(stream: 1).makeAsyncIterator()
        let surfaceUnit = await surfaceIterator.next()
        #expect(surfaceUnit.map { [UInt8]($0.data) } == popup)

        // Hiding the surface ends its stream.
        host.send(Self.service(#"{"t":"rb.surface.hide","surface":7}"#))
        #expect(await surfaceIterator.next() == nil)
        transport.stop()
    }

    @Test func aStreamNoSurfaceShowedHasNoUnits() async {
        let endpoint = RemoteRdLoopbackEndpoint(port: 4103)
        let transport = endpoint.flatMap { RemoteRdStreamTransport.remoteBrowser(endpoint: $0, user: "u", install: "i") }
        var iterator = transport?.surfaceAccessUnits(stream: 3).makeAsyncIterator()
        #expect(await iterator?.next() == nil)
    }
}
