import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite("Connectivity invalidation subscriber")
struct CmxConnectivityInvalidationSubscriberTests {
    @Test("parses the exact bounded revision-only frame")
    func parsesFrame() throws {
        let data = Data(
            #"{"type":"connectivity.invalidate","protocolVersion":1,"revision":42,"at":1800000000000}"#
                .utf8
        )

        #expect(try CmxConnectivityInvalidation.parse(data) == .init(
            revision: 42,
            acceptedAtMilliseconds: 1_800_000_000_000
        ))
    }

    @Test(
        "rejects route material, wrong protocol, booleans, and oversized frames",
        arguments: [
            #"{"type":"connectivity.invalidate","protocolVersion":1,"revision":1,"at":2,"routes":[]}"#,
            #"{"type":"connectivity.invalidate","protocolVersion":2,"revision":1,"at":2}"#,
            #"{"type":"connectivity.invalidate","protocolVersion":1,"revision":0,"at":2}"#,
            #"{"type":"connectivity.invalidate","protocolVersion":1,"revision":true,"at":2}"#,
            {
                let padding = String(
                    repeating: "p",
                    count: CmxConnectivityInvalidation.maximumFrameBytes
                )
                return #"{"type":"connectivity.invalidate","protocolVersion":1,"revision":1,"at":2,"pad":"\#(padding)"}"#
            }(),
        ]
    )
    func rejectsInvalidFrame(_ text: String) {
        #expect(throws: CmxConnectivityInvalidationError.invalidFrame) {
            try CmxConnectivityInvalidation.parse(Data(text.utf8))
        }
    }

    @Test("normalizes malformed JSON to the bounded invalid-frame error")
    func normalizesMalformedJSON() {
        #expect(throws: CmxConnectivityInvalidationError.invalidFrame) {
            try CmxConnectivityInvalidation.parse(Data(#"{"revision":"#.utf8))
        }
    }

    @Test("resolves the dedicated account WebSocket route")
    func resolvesSubscribeURL() throws {
        let base = try #require(URL(string: "https://presence.example.test/dev/"))
        #expect(
            CmxConnectivityInvalidationSubscriber.subscribeURL(serviceBaseURL: base)?
                .absoluteString
                == "wss://presence.example.test/dev/v1/connectivity/subscribe"
        )
        #expect(
            CmxConnectivityInvalidationSubscriber.subscribeURL(
                serviceBaseURL: try #require(URL(string: "ftp://presence.example.test"))
            ) == nil
        )
    }
}
