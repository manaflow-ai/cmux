import CmuxNextBrowser
import CmuxNextBrowserAutomation
import Foundation
import Testing
@testable import CmuxNextBrowserHost

/// The provider frames match cmux-browser-host's provider.rs byte for byte
/// in meaning: the JSON literals below are the shapes serde writes and reads
/// (provider.rs and provider_link.rs tests, relay-ext's tab.access).
@Suite struct ProviderCodecTests {
    static func object(_ json: String) -> NSDictionary {
        (try! JSONSerialization.jsonObject(with: Data(json.utf8))) as! NSDictionary
    }

    static func encodedObject(_ frame: ProviderFrame) throws -> NSDictionary {
        let bytes = try ProviderCodec.encode(frame)
        let length = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        #expect(length == bytes.count - 4)
        return (try JSONSerialization.jsonObject(with: bytes.dropFirst(4))) as! NSDictionary
    }

    static func decoded(_ json: String) throws -> ProviderFrame {
        try ProviderCodec.decode(Data(json.utf8))
    }

    static let helloJSON = #"""
    {"t":"hello","version":1,"provider_id":"app","install_id":"inst_1","secret":"s3cret-value","engines":["webkit","cef"],
     "tabs":[{"targetId":"tab_1","engine":"cef","workspace":"ws_1","profile":"agent","url":"https://example.com/","title":"Example","visible":false}]}
    """#

    static let hello = ProviderFrame.hello(
        version: 1, providerID: "app", installID: "inst_1", secret: ProviderSecret("s3cret-value"), engines: ["webkit", "cef"],
        tabs: [ProviderTabAnnounce(targetID: "tab_1", engine: "cef", workspace: "ws_1", profile: "agent",
                                   url: "https://example.com/", title: "Example", visible: false)])

    @Test func everyFrameEncodesToTheRustShape() throws {
        let cases: [(ProviderFrame, String)] = [
            (Self.hello, Self.helloJSON),
            (.helloAck(agentBundle: "agent();", agentBundleSHA: "abc"), #"{"t":"hello.ack","agent_bundle":"agent();","agent_bundle_sha":"abc"}"#),
            (.call(id: 7, method: "tab.info", params: .object(["targetId": .string("tab_1")])),
             #"{"t":"call","id":7,"method":"tab.info","params":{"targetId":"tab_1"}}"#),
            (.result(id: 7, result: .object(["url": .string("about:blank")]), error: nil), #"{"t":"result","id":7,"result":{"url":"about:blank"}}"#),
            (.result(id: 2, result: nil, error: DriverError(.evaluation, "boom", errorName: "TypeError").json),
             #"{"t":"result","id":2,"error":{"code":"evaluation","message":"boom","errorName":"TypeError"}}"#),
            (.event(name: "tab.closed", payload: .object(["targetId": .string("tab_1")])), #"{"t":"event","name":"tab.closed","payload":{"targetId":"tab_1"}}"#),
            (.cdpAttach(targetID: "tab_1"), #"{"t":"cdp.attach","targetId":"tab_1"}"#),
            (.cdpDetach(targetID: "a"), #"{"t":"cdp.detach","targetId":"a"}"#),
            (.cdp(targetID: "tab_1", message: #"{"id":1,"method":"Page.enable"}"#),
             #"{"t":"cdp","targetId":"tab_1","message":"{\"id\":1,\"method\":\"Page.enable\"}"}"#),
            (.lease(targetID: "tab_1", lease: nil), #"{"t":"lease","targetId":"tab_1","lease":null}"#),
            (.lease(targetID: "t", lease: ProviderLease(session: "s1", actor: "agent", onBehalfOf: "lawrence", origin: "cli", label: "Fix", sinceMs: 12)),
             #"{"t":"lease","targetId":"t","lease":{"session":"s1","actor":"agent","on_behalf_of":"lawrence","origin":"cli","label":"Fix","since_ms":12}}"#),
            (.userInput(targetID: "tab_1"), #"{"t":"user.input","targetId":"tab_1"}"#),
            (.tabAccess(targetID: "tab_1", extensionHostAccess: true, userOverride: false, extensions: ["Ext"]),
             #"{"t":"tab.access","targetId":"tab_1","extension_host_access":true,"user_override":false,"extensions":["Ext"]}"#),
            // serde skips an empty extensions list.
            (.tabAccess(targetID: "t", extensionHostAccess: false, userOverride: true, extensions: []),
             #"{"t":"tab.access","targetId":"t","extension_host_access":false,"user_override":true}"#),
        ]
        for (frame, json) in cases {
            #expect(try Self.encodedObject(frame) == Self.object(json), "\(frame)")
            #expect(try Self.decoded(json) == frame, "\(frame)")
        }
    }

    @Test func serdeDefaultsApplyOnDecode() throws {
        #expect(try Self.decoded(#"{"t":"tab.access","targetId":"t","extension_host_access":false}"#)
            == .tabAccess(targetID: "t", extensionHostAccess: false, userOverride: false, extensions: []))
        #expect(try Self.decoded(#"{"t":"call","id":1,"method":"tabs.list"}"#) == .call(id: 1, method: "tabs.list", params: .null))
        #expect(try Self.decoded(#"{"t":"lease","targetId":"t"}"#) == .lease(targetID: "t", lease: nil))
        #expect(try Self.decoded(#"{"t":"result","id":3}"#) == .result(id: 3, result: nil, error: nil))
        // The lease state passes through as the host wrote it, known or not.
        #expect(try Self.decoded(#"{"t":"lease","targetId":"t","lease":{"session":"s","actor":"a","origin":"cli","label":"L","since_ms":1,"state":"some_future_state"}}"#)
            == .lease(targetID: "t", lease: ProviderLease(session: "s", actor: "a", origin: "cli", label: "L", sinceMs: 1, state: "some_future_state")))
        #expect(try Self.decoded(#"{"t":"future.frame","x":1}"#) == .unknown(tag: "future.frame"))
        #expect(throws: ProviderCodecError.self) { try Self.decoded(#"{"t":"cdp","targetId":"t"}"#) }
        #expect(throws: ProviderCodecError.self) { try Self.decoded("not json") }
    }

    @Test func secretAndPayloadsStayOutOfDescriptions() {
        let call = ProviderFrame.call(id: 1, method: "input.insertText", params: .object(["text": .string("hunter2")]))
        let cdp = ProviderFrame.cdp(targetID: "t", message: #"{"params":{"text":"hunter2"}}"#)
        var dumped = ""
        dump(Self.hello, to: &dumped)
        let text = "\(Self.hello) \(String(reflecting: Self.hello)) \(dumped) \(call) \(cdp) \(ProviderSecret("s3cret-value"))"
        #expect(!text.contains("s3cret-value"))
        #expect(!text.contains("hunter2"))
        #expect(text.contains("input.insertText"))
    }

    @Test func decoderWaitsForWholeFramesAndRefusesOversize() throws {
        let a = try ProviderCodec.encode(.cdpDetach(targetID: "a"))
        let b = try ProviderCodec.encode(.userInput(targetID: "b"))
        var decoder = ProviderFrameDecoder()
        decoder.push(a.prefix(3))
        let partial = try decoder.next()
        decoder.push(a.dropFirst(3))
        decoder.push(b.dropLast())
        let first = try decoder.next()
        let waiting = try decoder.next()
        decoder.push(b.suffix(1))
        let second = try decoder.next()
        #expect(partial == nil)
        #expect(first == .cdpDetach(targetID: "a"))
        #expect(waiting == nil)
        #expect(second == .userInput(targetID: "b"))

        var small = ProviderFrameDecoder(maxFrameBytes: 8)
        small.push(Data([0, 0, 0, 9]))
        var refused: ProviderCodecError?
        do throws(ProviderCodecError) { _ = try small.next() } catch { refused = error }
        #expect(refused == .tooLarge(9))
    }
}
