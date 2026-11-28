import Foundation
import Testing
@testable import CmuxNextDaemon

struct LocalConversationRequestWireTests {
    private func check<R: DaemonRequest>(_ request: R, capability: String, line: String) throws {
        #expect(R.requiredCapability == capability)
        #expect(try WireCoding.encodeRequest(request, id: 1) == Data(line.utf8))
    }

    @Test func readsKeepTheirGatesAndWireKeys() throws {
        try check(ListConversationsRequest(), capability: "local-conversations-v1",
                  line: #"{"cmd":"conversation-list","id":1}"#)
        try check(ConversationLiveRequest(conversation: "c"), capability: "chief-live-v1",
                  line: #"{"cmd":"conversation-live","conversation":"c","id":1}"#)
        try check(ConversationLinkResolveRequest(url: "cmux://c"), capability: "conversation-tree-v1",
                  line: #"{"cmd":"conversation-link-resolve","id":1,"url":"cmux://c"}"#)
        try check(ConversationSearchRequest(query: "text", limit: -1), capability: "conversation-search-v1",
                  line: #"{"cmd":"conversation-search","id":1,"limit":-1,"query":"text"}"#)
    }

    @Test func writesKeepTheirPrincipalAndOptionalActor() throws {
        let gate = "local-conversations-v1"
        var create = CreateConversationRequest(idempotencyKey: "k", title: "t", participants: [])
        try check(create, capability: gate,
                  line: #"{"cmd":"conversation-create","id":1,"idempotency_key":"k","participants":[],"title":"t"}"#)
        create.actor = "a"
        try check(create, capability: gate,
                  line: #"{"actor":"a","cmd":"conversation-create","id":1,"idempotency_key":"k","participants":[],"title":"t"}"#)
        try check(ConversationTypingRequest(conversation: "c", on: false), capability: gate,
                  line: #"{"cmd":"conversation-typing","conversation":"c","id":1,"on":false}"#)
        try check(ConversationTypingRequest(conversation: "c", actor: "a", on: true), capability: gate,
                  line: #"{"actor":"a","cmd":"conversation-typing","conversation":"c","id":1,"on":true}"#)
        try check(ConversationAgentTokenRequest(participant: "a"), capability: gate,
                  line: #"{"cmd":"conversation-agent-token","id":1,"participant":"a"}"#)
        try check(ConversationBindRequest(participant: "a", token: "fixture"), capability: gate,
                  line: #"{"cmd":"conversation-bind","id":1,"participant":"a","token":"fixture"}"#)
    }
}
