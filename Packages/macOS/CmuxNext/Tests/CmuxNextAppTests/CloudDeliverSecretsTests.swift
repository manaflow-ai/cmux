import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextRemote
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
        #expect(descriptor.arguments.map(\.name) == ["repo", "names"], "the person names the scope and the names; nothing takes a value")
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

    @Test func namesAreSecretNamesEachOnceAndABareOrBadListIsRefused() throws {
        let names = { (value: ActionValue) in try CloudHandlers.secretNames(ActionInvocation(arguments: ["names": value], origin: .cli)) }
        #expect(try CloudHandlers.secretNames(ActionInvocation(origin: .cli)) == nil)
        #expect(try names(.string("API_KEY, DATABASE_URL,API_KEY")) == ["API_KEY", "DATABASE_URL"])
        for (value, shown) in [(ActionValue.bool(true), "--names"), (.string(""), ""), (.string("API_KEY,bad-name"), "API_KEY,bad-name"),
                               (.string("1X"), "1X"), (.string("PATH"), "PATH"), (.string("A,,B"), "A,,B")] {
            #expect(throws: ActionFailure(message: CloudStrings.secretNamesInvalid(shown))) { try names(value) }
        }
    }

    @Test func aCloudMachineTakesItsDeclaredNamesNeverNames() {
        let f = CloudCLITargetTests.fixture()
        let target = ActionTargetRef(kind: .machine, id: f.session.machineID)
        #expect(throws: ActionFailure(message: CloudStrings.secretNamesOnCloudMachine)) {
            try CloudHandlers.deliverSecrets(ActionInvocation(target: target, arguments: ["names": .string("API_KEY")], origin: .cli), f.context)
        }
    }

    /// An SSH machine has no machine config: the person names the set, and its file then holds exactly that.
    @Test func anSSHMachineNeedsTheNamesFromThePerson() throws {
        let f = CloudCLITargetTests.fixture()
        let ssh = try TabMachineColorTests.sshMachine(f.services.machines)
        #expect(CloudHandlers.sshMachine("lab", f.context) === ssh, "its sidebar name")
        #expect(CloudHandlers.sshMachine(ssh.host.destination.sshArgument, f.context) === ssh, "its destination")
        #expect(!CloudHandlers.isCloudMachine(ssh.machineID, f.context) && CloudHandlers.isCloudMachine(f.session.machineID, f.context))
        #expect(throws: ActionFailure(message: CloudStrings.secretNamesRequired)) {
            try CloudHandlers.deliverSecrets(ActionInvocation(target: ActionTargetRef(kind: .machine, id: "lab"), origin: .cli), f.context)
        }
    }

    /// The verb is there for an own machine with no Cloud workspace open: a `--target machine:` run
    /// implies the context the catalog requires, and the handler (not the catalog) decides.
    @Test func anOwnMachineTargetIsAvailableWithoutACloudWorkspace() throws {
        let f = CloudCLITargetTests.fixture()
        _ = try TabMachineColorTests.sshMachine(f.services.machines)
        let registry = ActionRegistry(catalog: f.services.registry.descriptors)
        #expect(!registry.context.contains(.cloudWorkspace))
        let run = ActionInvocation(target: ActionTargetRef(kind: .machine, id: "lab"), origin: .cli)
        #expect(registry.isAvailable("cloudDeliverSecrets", for: run))
    }

    @Test func aPeerIsDeliveredToOverItsSSHRouteOnly() throws {
        let peers = [AcpmuxPeerList.Peer(name: "dev-box", connected: true, url: "ssh://ann@dev-box:47811"),
                     AcpmuxPeerList.Peer(name: "tail-box", connected: true, url: "ws://100.64.0.9:47811"),
                     AcpmuxPeerList.Peer(name: "bare", connected: false)]
        #expect(CloudHandlers.peerRoute("Dev-Box", among: peers) == .ssh(try SSHDestination(parsing: "ann@dev-box")))
        #expect(CloudHandlers.peerRoute("tail-box", among: peers) == .noSSH)
        #expect(CloudHandlers.peerRoute("bare", among: peers) == .noSSH)
        #expect(CloudHandlers.peerRoute("gone", among: peers) == .unknown)
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
