import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// `cmux cloud deliver-secrets --target machine:<id> [--repo OWNER/NAME]` (CloudHandlers+Machine,
/// CloudMachineSecrets): a CLI verb on a machine that answers with its result, and the daemon's
/// `wait-for` the delivery waits on, which carries a pattern, never a value.
@MainActor @Suite(.serialized)
struct CloudDeliverSecretsTests {
    @Test func theActionIsACLIVerbOnAMachineThatAnswersWithItsResult() throws {
        let descriptor = try #require(ActionRegistry(catalog: CloudCLITargetTests.fixture().services.registry.descriptors)
            .descriptor(for: "cloudDeliverSecrets"))
        #expect(descriptor.cliName == "cloud deliver-secrets")
        #expect(descriptor.targets == [.machine])
        #expect(descriptor.waitsForResult)
        #expect(descriptor.arguments.map(\.name) == ["repo"], "the person names the scope; nothing takes a value")
    }

    @Test func aRepoFlagWithNoValueOrNotOwnerSlashNameIsRefusedNeverTakenForGlobal() {
        let f = CloudCLITargetTests.fixture()
        let target = ActionTargetRef(kind: .machine, id: f.session.machineID)
        for (value, shown) in [(ActionValue.bool(true), "--repo"), (.string("acme"), "acme"), (.string(""), "")] {
            #expect(throws: ActionFailure(message: CloudStrings.secretRepoInvalid(shown))) {
                try CloudHandlers.deliverSecrets(ActionInvocation(target: target, arguments: ["repo": value], origin: .cli), f.context)
            }
        }
    }

    @Test func waitForSendsThePatternAndTheTimeoutInMilliseconds() throws {
        let data = try JSONEncoder().encode(WaitForTextRequest(surface: SurfaceID(rawValue: 7), pattern: "CMUX-SECRETS-READY ab|CMUX-SECRETS-ERR [a-z-]+", timeoutMs: 60_000))
        let sent = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(sent["pattern"] as? String == "CMUX-SECRETS-READY ab|CMUX-SECRETS-ERR [a-z-]+")
        #expect(sent["timeout_ms"] as? Int == 60_000)
        #expect(sent["surface"] != nil)
        #expect(WaitForTextRequest.command == "wait-for")
    }
}
