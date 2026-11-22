import CmuxNextBrowserAutomation
@testable import CmuxNextBrowserHost
import Foundation
import Testing

/// `input {event}` frames (automation.input v1 from the browser host) fan out
/// to every registered consumer, like lease frames; no settable closure.
@MainActor
@Suite struct BrowserHostProviderInputTests {
    private static let event: DriverJSON = .object([
        "v": .number(1), "session_id": .string("s1"), "target_id": .string("c1"), "seq": .number(0),
        "kind": .string("click"), "space": .string("viewport"),
        "point": .object(["x": .number(120.5), "y": .number(48)]), "t_ms": .number(1000),
    ])

    @Test func everyConsumerHearsEveryInputUntilItCancels() async throws {
        let h = ProviderHarness(tabs: [tab("c1", .cef)])
        var first: [DriverJSON] = []
        var second: [DriverJSON] = []
        let a = h.provider.observeInputs { first.append($0) }
        let b = h.provider.observeInputs { second.append($0) }
        let (host, _) = await h.connected()
        _ = await host.next() // tab.access
        host.ack()
        host.send(.input(event: Self.event))
        host.send(.call(id: 1, method: "tabs.list", params: .object([:])))
        _ = await host.next()
        b.cancel()
        host.send(.input(event: Self.event))
        host.send(.call(id: 2, method: "tabs.list", params: .object([:])))
        _ = await host.next()
        #expect(first == [Self.event, Self.event])
        #expect(second == [Self.event], "a cancelled consumer hears nothing more")
        _ = a
    }

    @Test func theInputFrameRoundTripsWithTheRustWireShape() throws {
        let frame = ProviderFrame.input(event: Self.event)
        let object = ProviderCodec.jsonObject(frame)
        #expect(object["t"] as? String == "input")
        #expect((object["event"] as? [String: Any])?["session_id"] as? String == "s1")
        let bytes = try ProviderCodec.encode(frame)
        #expect(try ProviderCodec.decode(bytes.dropFirst(4)) == frame)
        #expect(frame.description == "input(s1#0)", "the description names the session and seq only")
    }

    @Test func anInputFrameWithoutAnEventIsRefused() {
        #expect(throws: ProviderCodecError.missing(field: "event", in: "input")) {
            try ProviderCodec.decode(Data(#"{"t":"input"}"#.utf8))
        }
    }
}
