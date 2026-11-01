@testable import CmuxNextApp
@testable import CmuxNextCloud
import Foundation
import Testing

/// cmux-platform#89, part 1: on the Cloud app server link, an app-started chat and a folder-trust
/// call carry the owner word only while that link's own `cloud.machine.connect` answer said the
/// signed-in caller owns the machine (`vm_kind: "owner"`, the classic attach answer's value). Before,
/// the app-link session gave no owner answer at all, so every start and trust there was refused
/// with `agent_session.host_unverified`.
@MainActor
struct CloudAppLinkOwnerAnswerTests {
    private nonisolated static let key = CloudLinkKey(machine: "vm_aaaaaaaaaaaaaaaaaaaa")

    private nonisolated static func answer(_ vmKind: String?) -> Data {
        var object: [String: Any] = ["machine": key.machine, "state": "up", "generation": 3, "socket": "/tmp/cmux-link.sock"]
        if let vmKind { object["vm_kind"] = vmKind }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func resolver(_ vmKind: String?) -> CloudConnectOpResolver {
        CloudConnectOpResolver(run: { _, _, _, _ in answer(vmKind) }, check: { _ in })
    }

    @Test func onlyAnExactOwnerValueMarksTheConnectAsTheCallersOwnMachine() async throws {
        #expect(try await Self.resolver("owner").open(Self.key, intent: "i", origin: .user).callerOwnsVM)
        for other in [nil, "", "Owner", " owner", "teammate", "team", "guest"] {
            let socket = try await Self.resolver(other).open(Self.key, intent: "i", origin: .user)
            #expect(!socket.callerOwnsVM, "vm_kind \(other ?? "absent")")
        }
    }

    /// A `vm_kind` that is not a string (a server mid-rollout) is no owner answer, and the machine
    /// still connects as it did before the field existed.
    @Test(arguments: ["0", "true", "[\"owner\"]", "{\"kind\":\"owner\"}", "null"])
    func aVMKindOfAnotherTypeIsNotTheOwnerAndStillConnects(raw: String) async throws {
        let body = #"{"machine":"vm_aaaaaaaaaaaaaaaaaaaa","state":"up","generation":3,"socket":"/tmp/cmux-link.sock","vm_kind":"# + raw + "}"
        let resolver = CloudConnectOpResolver(run: { _, _, _, _ in Data(body.utf8) }, check: { _ in })
        let socket = try await resolver.open(Self.key, intent: "i", origin: .user)
        #expect(socket.path == "/tmp/cmux-link.sock")
        #expect(!socket.callerOwnsVM)
    }

    @Test func theOwnerAnswerHoldsOnlyWhileItsOwnConnectIsUp() async throws {
        let link = CloudLinkSession(key: Self.key, resolver: Self.resolver("owner"))
        #expect(await link.ownerLink == nil, "no connect yet")
        let first = try await link.connect(origin: .user)
        let id = try #require(await link.ownerLink)
        _ = try await link.endpoint(first)
        #expect(await link.ownerLink == id, "the attached connection keeps its connect's answer")

        // A new connect is another link: a start that read the old id is refused.
        _ = try await link.connect(origin: .user)
        let second = try #require(await link.ownerLink)
        #expect(second != id)

        // A down, a revoke, a second endpoint call (the connection dropped) or a pause ends the
        // answer with its link.
        _ = await link.apply(CloudLinkChange(key: Self.key, state: .down, generation: 3, reason: "eof"))
        #expect(await link.ownerLink == nil)
        _ = try await link.connect(origin: .user)
        #expect(await link.ownerLink != nil)
        _ = await link.apply(CloudLinkChange(key: Self.key, state: .revoked, generation: 3, reason: "revoked"))
        #expect(await link.ownerLink == nil)
        let dropped = try await link.connect(origin: .user)
        _ = try await link.endpoint(dropped)
        _ = try? await link.endpoint(dropped)
        #expect(await link.ownerLink == nil)
        _ = try await link.connect(origin: .user)
        #expect(await link.ownerLink != nil)
        await link.end(reason: "paused")
        #expect(await link.ownerLink == nil)
    }

    @Test func mobileSnapshotDoesNotConsumeTheEndpointAndIsWithdrawnWithItsLink() async throws {
        let link = CloudLinkSession(key: Self.key, resolver: Self.resolver("owner"))
        #expect(await link.currentLinkSocket == nil)
        let ticket = try await link.connect(origin: .user)
        let snapshot = try #require(await link.currentLinkSocket)
        #expect(snapshot.callerOwnsVM)
        #expect(snapshot.key == Self.key)
        #expect(try await link.endpoint(ticket) == snapshot.path)
        #expect(await link.currentLinkSocket == snapshot)
        _ = await link.apply(CloudLinkChange(key: Self.key, state: .revoked, generation: 3, reason: "removed"))
        #expect(await link.currentLinkSocket == nil)

        let teammate = CloudLinkSession(key: Self.key, resolver: Self.resolver("team"))
        _ = try await teammate.connect(origin: .user)
        #expect(await teammate.currentLinkSocket?.callerOwnsVM == false)
    }

    /// The closure the tab's chat start and trust calls read (AgentTabs+Wiring): the app link's own
    /// answer. AgentSessionAttachClient sends the owner word only when its two reads (before the
    /// connection, as the call goes out) give the same non-nil id (AgentSessionStartOwnerLinkTests),
    /// so a reconnect or a revoke between them refuses the call.
    @Test func theTabsOwnerClosureFollowsTheAppLinkAcrossAReconnectAndARevoke() async throws {
        let appLink = CloudLinkSession(key: Self.key, resolver: Self.resolver("owner"))
        let ownerLink = CloudMachineLinks(appLink: appLink, link: nil).ownerLink
        #expect(await ownerLink() == nil, "not connected: refused")
        _ = try await appLink.connect(origin: .user)
        let before = try #require(await ownerLink())
        #expect(await ownerLink() == before, "the same link: the owner word goes out")
        _ = try await appLink.connect(origin: .user)
        #expect(await ownerLink() != before, "a reconnect between the reads: refused")
        _ = await appLink.apply(CloudLinkChange(key: Self.key, state: .revoked, generation: 3, reason: "revoked"))
        #expect(await ownerLink() == nil, "revoked: refused")

        let team = CloudLinkSession(key: Self.key, resolver: Self.resolver("team"))
        _ = try await team.connect(origin: .user)
        #expect(await CloudMachineLinks(appLink: team, link: nil).ownerLink() == nil, "a teammate: refused")
    }

    @Test func aConnectThatDoesNotSayOwnerGivesNoOwnerAnswer() async throws {
        let link = CloudLinkSession(key: Self.key, resolver: Self.resolver(nil))
        _ = try await link.connect(origin: .user)
        #expect(await link.ownerLink == nil)
    }
}
