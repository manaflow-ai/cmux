import CmuxMobileAgentChat
import CmuxMobileTransport
import Testing
@testable import CmuxMobileLive

/// A request made inside a phone user action carries its trace id as `_meta.traceId`, which
/// acpmux's tracer keys its spans by (cmux#55505 `trace_id_of`), beside the `_meta` it had.
struct AcpmuxTraceMetaTests {
    @Test func outsideAnActionParamsAreUnchanged() {
        let params: JSONValue = .object(["sessionId": .string("s1")])
        #expect(AcpmuxConnection.traced(params) == params)
    }

    @Test func insideAnActionTheTraceIDJoinsTheMeta() {
        let params: JSONValue = .object([
            "sessionId": .string("s1"),
            "_meta": .object(["acpmux": .object(["promptId": .string("p1")])]),
        ])
        let traced = PhoneTrace.$traceID.withValue("0af7651916cd43dd8448eb211c80319c") {
            AcpmuxConnection.traced(params)
        }
        #expect(traced == .object([
            "sessionId": .string("s1"),
            "_meta": .object([
                "acpmux": .object(["promptId": .string("p1")]),
                "traceId": .string("0af7651916cd43dd8448eb211c80319c"),
            ]),
        ]))
    }

    @MainActor @Test func aPromptCarriesItsSendTraceID() {
        let prompt = AcpmuxSessionSource.HeldPrompt(text: "hi", attachments: [], promptID: "p1", steer: false, resend: false,
                                                    blocks: [], at: .now, traceID: "4bf92f3577b34da6a3ce929d0e0e4736")
        let traced = PhoneTrace.$traceID.withValue(prompt.traceID) {
            AcpmuxConnection.traced(AcpmuxSessionSource.promptParams(prompt, session: "s1"))
        }
        #expect(traced["_meta"]?["traceId"]?.stringValue == "4bf92f3577b34da6a3ce929d0e0e4736")
        #expect(traced["_meta"]?["acpmux"]?["promptId"]?.stringValue == "p1")
    }
}
