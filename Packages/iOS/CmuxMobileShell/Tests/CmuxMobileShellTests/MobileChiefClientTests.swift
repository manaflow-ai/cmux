import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxMobileShell

@Suite
struct MobileChiefClientTests {
    @Test
    func decodesAustinChiefReadWireShape() throws {
        let data = Data(
            """
            {
              "conversation":"chief-main",
              "working":true,
              "messages":[{
                "id":"m-1",
                "seq":7,
                "author_id":"agent_mux",
                "author":"Chief",
                "author_kind":"chief",
                "text":"I am on it.",
                "at":"2026-10-16T12:30:45Z",
                "parts":["text","work"],
                "thread_root":"m-0"
              }]
            }
            """.utf8
        )

        let result = try ChatWireCoding().decode(MobileChiefReadResult.self, from: data)
        #expect(result.conversation == "chief-main")
        #expect(result.working)
        #expect(result.messages == [
            MobileChiefMessage(
                id: "m-1",
                seq: 7,
                authorID: "agent_mux",
                author: "Chief",
                authorKind: "chief",
                text: "I am on it.",
                at: ISO8601DateFormatter().date(from: "2026-10-16T12:30:45Z")!,
                parts: ["text", "work"],
                threadRoot: "m-0"
            ),
        ])
    }

    @Test
    func toleratesOlderStatusAndConversationRows() throws {
        let coding = ChatWireCoding()
        let status = try coding.decode(MobileChiefStatus.self, from: Data("{\"started\":true}".utf8))
        #expect(status.started)
        #expect(status.working.isEmpty)
        #expect(status.unread == 0)

        let row = try coding.decode(
            MobileChiefConversation.self,
            from: Data("{\"id\":\"c-1\"}".utf8)
        )
        #expect(row.id == "c-1")
        #expect(row.title == "c-1")
        #expect(row.preview.isEmpty)
    }

    @Test
    func decodesSendCorrelationID() throws {
        let result = try ChatWireCoding().decode(
            MobileChiefSendResult.self,
            from: Data(
                "{\"conversation\":\"chief-main\",\"client_message_id\":\"client-7\",\"queued\":false}".utf8
            )
        )
        #expect(result.clientMessageID == "client-7")
    }

    @Test
    func chiefCapabilityGatesReadPaths() {
        #expect(!MobileChiefCapability.isAvailable(in: [MobileChiefCapability.status]))
        #expect(!MobileChiefCapability.isAvailable(in: [MobileChiefCapability.conversations]))
        #expect(!MobileChiefCapability.isAvailable(in: [
            MobileChiefCapability.conversations,
            MobileChiefCapability.read,
        ]))
        #expect(MobileChiefCapability.isAvailable(in: [
            MobileChiefCapability.conversations,
            MobileChiefCapability.read,
            MobileChiefCapability.send,
        ]))
        #expect(!MobileChiefCapability.isAvailable(in: ["mobile.chat.sessions"]))
    }
}
