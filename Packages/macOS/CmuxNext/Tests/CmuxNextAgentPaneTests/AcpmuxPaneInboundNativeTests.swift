import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A daemon frame from URLSessionWebSocketTask is a bridged NSString. The inbound pass reads its
/// UTF-8 several times (size, duplicate-key check, method scan, markers); on a bridged string each
/// read walks it one character at a time, so the socket makes each frame native once on arrival.
struct AcpmuxPaneInboundNativeTests {
    /// A `session/update` chunk of about `bytes` bytes, with the non-ASCII text a transcript has
    /// (CoreFoundation keeps such a string as UTF-16, as it does for the daemon's frames).
    static func chunk(bytes: Int, index: Int = 0) -> String {
        let line = "Résumé of step \(index) — checks pass ✓, “quoted” text and a tab\\t and newline\\n. "
        let text = String(repeating: line, count: max(1, bytes / line.utf8.count))
        return #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":""# + text + #""}}}}"#
    }

    static func isNative(_ text: String) -> Bool {
        text.utf8.withContiguousStorageIfAvailable { _ in true } == true
    }

    @Test func nativeUTF8KeepsTextAndNativeStringsAsTheyAre() {
        let text = Self.chunk(bytes: 4_096)
        #expect(Self.isNative(text))
        #expect(AcpmuxPaneSocket.nativeUTF8(text) == text)
        #expect(AcpmuxPaneSocket.nativeUTF8("") == "")
    }

    #if canImport(ObjectiveC)
    /// What URLSessionWebSocketTask's `.string(text)` hands over: a CFString decoded from UTF-8.
    static func bridged(_ text: String) -> String {
        NSString(data: Data(text.utf8), encoding: String.Encoding.utf8.rawValue)! as String
    }

    @Test func nativeUTF8TranscodesABridgedFrame() {
        let text = Self.chunk(bytes: 8_192)
        let frame = Self.bridged(text)
        #expect(!Self.isNative(frame))
        let native = AcpmuxPaneSocket.nativeUTF8(frame)
        #expect(Self.isNative(native))
        #expect(native == text)
        #expect(Array(native.utf8) == Array(text.utf8))
    }

    /// Red at base: an opaque notification reached the page queue as the bridged string it arrived as.
    @MainActor @Test func socketQueuesABridgedFrameAsNativeUTF8() async {
        let (woken, wake) = AsyncStream<Void>.makeStream()
        let transport = AgentPaneTransport()
        let socket = AcpmuxPaneSocket(
            request: URLRequest(url: URL(string: "ws://127.0.0.1")!),
            limits: transport.limits,
            options: transport.permissionOptions,
            sessions: transport.sessions,
            ids: AcpmuxRequestIds(),
            signal: { wake.yield() })
        let text = Self.chunk(bytes: 8_192)
        let frame = Self.bridged(text)
        #expect(!Self.isNative(frame))
        socket.receiveLocalReply(frame)
        for await _ in woken { break }
        let batch = socket.take(maximumFrames: 10, maximumBytes: 1 << 20)
        #expect(batch.frames == [text])
        #expect(batch.frames.allSatisfy(Self.isNative))
    }

    /// The inbound pass over 1,000 bridged frames as they arrive, and over the same frames made
    /// native first (the transcode included). Prints ms per 1,000 frames for the PR's table.
    @Test(arguments: [2_048, 20_480])
    func inboundPassOverBridgedFramesIsFasterNative(bytes: Int) {
        let frames = (0..<1_000).map { Self.bridged(Self.chunk(bytes: bytes, index: $0)) }
        #expect(frames.allSatisfy { !Self.isNative($0) })
        let ids = AcpmuxRequestIds()
        func pass(_ convert: Bool) -> Duration {
            ContinuousClock().measure {
                for frame in frames {
                    let text = convert ? AcpmuxPaneSocket.nativeUTF8(frame) : frame
                    _ = text.utf8.count
                    guard case .page = ids.toPage(text) else { Issue.record("frame was not forwarded"); return }
                }
            }
        }
        let bridged = pass(false)
        let native = pass(true)
        print("inbound pass, 1,000 frames of \(bytes) B: bridged \(bridged), native \(native)")
        #expect(native < bridged)
    }
    #endif

    /// A reply with an escaped character is parsed once, not twice (escape check, then reply path).
    @Test func escapedReplyStillReachesThePageWithItsId() throws {
        let ids = AcpmuxRequestIds()
        let relay = try #require(ids.begin(pageID: "7", method: "session/list"))
        let reply = #"{"jsonrpc":"2.0","id":\#(relay),"result":{"sessions":[{"title":"a\nb"}]}}"#
        guard case .page(let fresh, let object, let method) = ids.toPage(reply) else {
            Issue.record("reply was not forwarded")
            return
        }
        #expect(method == "session/list")
        #expect(object?["id"] as? Int == 7)
        #expect(fresh.contains(#""id":7"#))
    }
}
