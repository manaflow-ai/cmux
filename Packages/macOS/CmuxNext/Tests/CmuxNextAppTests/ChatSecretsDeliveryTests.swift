import CmuxNextAccounts
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemonService
import Foundation
import Testing

/// `cmux agent deliver-secrets --target agent-chat:<session id> --names A,B` (CloudHandlers+OwnMachineSecrets, CmuxNextAccounts ChatSecrets,
/// hq RFD 0211 VM item 4): one chat's secrets, sent to this Mac's acpmux (`_acpmux/chat_secrets_set`),
/// which holds them in memory with a TTL for that chat only (acpmux `chat_secrets.rs`, its own tests).
@MainActor @Suite(.serialized)
struct ChatSecretsDeliveryTests {
    @Test func theActionIsACLIVerbOnOneChatThatAnswersWithItsResult() throws {
        let descriptor = try #require(ActionRegistry(catalog: CloudCLITargetTests.fixture().services.registry.descriptors)
            .descriptor(for: "agentPane.deliverSecrets"))
        #expect(descriptor.cliName == "agent deliver-secrets")
        #expect(descriptor.targets.contains(.agentChat))
        #expect(descriptor.waitsForResult)
        #expect(descriptor.arguments.map(\.name) == ["names", "repo"], "the person names the secrets; nothing takes a value")
    }

    @Test func anAgentChatTargetNamesItsSession() {
        let f = CloudCLITargetTests.fixture()
        let target = ActionTargetRef(kind: .agentChat, id: "sess-42")
        #expect(CloudHandlers.chatSession(ActionInvocation(target: target, origin: .cli), f.context) == "sess-42")
        #expect(CloudHandlers.chatSession(ActionInvocation(target: ActionTargetRef(kind: .agentChat, id: ""), origin: .cli), f.context) == nil)
    }

    @Test func namesAreRequiredAndABadRepoIsRefusedBeforeAnythingIsRead() {
        let f = CloudCLITargetTests.fixture()
        let target = ActionTargetRef(kind: .agentChat, id: "sess-42")
        #expect(throws: ActionFailure(message: CloudStrings.secretNamesRequired)) {
            try CloudHandlers.deliverSecretsToChat(ActionInvocation(target: target, origin: .cli), f.context)
        }
        #expect(throws: ActionFailure(message: CloudStrings.secretNamesInvalid("API_KEY,bad-name"))) {
            try CloudHandlers.deliverSecretsToChat(ActionInvocation(target: target, arguments: ["names": .string("API_KEY,bad-name")], origin: .cli), f.context)
        }
        #expect(throws: ActionFailure(message: CloudStrings.secretRepoInvalid("acme"))) {
            try CloudHandlers.deliverSecretsToChat(ActionInvocation(target: target, arguments: ["names": .string("API_KEY"), "repo": .string("acme")], origin: .cli), f.context)
        }
    }

    /// The request is the shape acpmux `server/secrets.rs` reads: the session and a name-to-value map, no TTL
    /// (acpmux's own one-hour default, capped by it), and nothing else.
    @Test func theRequestCarriesTheSessionAndTheNamedValuesOnly() throws {
        let params = AcpmuxChatSecrets.params(session: "sess-42", values: [("API_KEY", "v1"), ("DATABASE_URL", "v2")])
        #expect(Set(params.keys) == ["sessionId", "secrets"])
        #expect(params["sessionId"] as? String == "sess-42")
        #expect(try #require(params["secrets"] as? [String: String]) == ["API_KEY": "v1", "DATABASE_URL": "v2"])
    }
}
