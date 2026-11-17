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
              "has_more":true,
              "change_cursor":"cursor-7",
              "messages":[{
                "id":"m-1",
                "seq":7,
                "author_id":"agent_mux",
                "author":"Chief",
                "author_kind":"chief",
                "text":"I am on it.",
                "at":"2026-10-16T12:30:45Z",
                "parts":["text","work"],
                "part_payloads":[{
                  "kind":"work",
                  "work":{"session":"acp-1","host":"builder","title":"Ship it","status":"running","preview":"Building"}
                }],
                "thread_root":"m-0"
              }]
            }
            """.utf8
        )

        let result = try ChatWireCoding().decode(MobileChiefReadResult.self, from: data)
        #expect(result.conversation == "chief-main")
        #expect(result.working)
        #expect(result.hasMore)
        #expect(result.changeCursor == "cursor-7")
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
                partPayloads: [MobileChiefPart(
                    kind: "work",
                    work: MobileChiefWork(
                        session: "acp-1", host: "builder", title: "Ship it", status: "running", preview: "Building"
                    )
                )],
                threadRoot: "m-0"
            ),
        ])
    }

    @Test
    func decodesStructuredApprovalAndQuestionPayloads() throws {
        let data = Data(
            """
            {
              "id":"m-2", "seq":8, "author_id":"chief", "author":"Chief", "author_kind":"chief",
              "text":"Choose", "at":"2026-10-16T12:30:45Z", "parts":["approval","question"],
              "part_payloads":[
                {"kind":"approval","approval":{"request":"r-1","prompt":"Run deploy?","options":["allow","deny"]}},
                {"kind":"question","question":{
                  "id":"q-1",
                  "source":{"harness":"chief","session":"chief-main","agentName":"Chief"},
                  "items":[{"id":"q0","prompt":"Which region?","options":[{"id":"us","label":"US"}]}],
                  "state":{"kind":"pending"}
                }}
              ]
            }
            """.utf8
        )

        let message = try ChatWireCoding().decode(MobileChiefMessage.self, from: data)
        #expect(message.partPayloads.count == 2)
        #expect(message.partPayloads[0].approval == MobileChiefApproval(
            request: "r-1", prompt: "Run deploy?", options: ["allow", "deny"]
        ))
        #expect(message.partPayloads[1].question?.id == "q-1")
        #expect(message.partPayloads[1].question?.items.first?.prompt == "Which region?")
    }

    @Test
    func decodesLegacyChiefMessageWithoutStructuredPayloads() throws {
        let data = Data(
            """
            {"id":"m-old","seq":1,"author_id":"a","author":"A","author_kind":"agent",
             "text":"Hello","at":"2026-10-16T12:30:45Z","parts":["text"]}
            """.utf8
        )

        let message = try ChatWireCoding().decode(MobileChiefMessage.self, from: data)
        #expect(message.parts == ["text"])
        #expect(message.partPayloads.isEmpty)
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

        let snapshot = try coding.decode(
            MobileChiefConversationSnapshot.self,
            from: Data("{\"conversations\":[{\"id\":\"c-1\"}],\"change_cursor\":\"cursor-1\"}".utf8)
        )
        #expect(snapshot.conversations.map(\.id) == ["c-1"])
        #expect(snapshot.changeCursor == "cursor-1")
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
    func decodesMarkReadResult() throws {
        let result = try ChatWireCoding().decode(
            MobileChiefMarkReadResult.self,
            from: Data("{\"conversation\":\"chief-main\",\"up_to_seq\":7,\"marked\":true}".utf8)
        )
        #expect(result.conversation == "chief-main")
        #expect(result.upToSeq == 7)
        #expect(result.marked)
    }

    @Test
    func chiefCapabilityRequiresInteractiveActions() {
        #expect(!MobileChiefCapability.isAvailable(in: [MobileChiefCapability.status]))
        #expect(!MobileChiefCapability.isAvailable(in: [MobileChiefCapability.conversations]))
        let readAndSend: Set<String> = [
            MobileChiefCapability.conversations,
            MobileChiefCapability.read,
            MobileChiefCapability.markRead,
            MobileChiefCapability.send,
        ]
        #expect(!MobileChiefCapability.isAvailable(in: readAndSend))
        #expect(!MobileChiefCapability.isAvailable(in: readAndSend.union([MobileChiefCapability.stop])))
        #expect(!MobileChiefCapability.isAvailable(in: readAndSend.union([MobileChiefCapability.stop, MobileChiefCapability.approve])))
        #expect(MobileChiefCapability.isAvailable(in: [
            MobileChiefCapability.conversations,
            MobileChiefCapability.read,
            MobileChiefCapability.markRead,
            MobileChiefCapability.send,
            MobileChiefCapability.stop,
            MobileChiefCapability.approve,
            MobileChiefCapability.answer,
        ]))
        #expect(!MobileChiefCapability.isAvailable(in: ["mobile.chat.sessions"]))
    }
}
