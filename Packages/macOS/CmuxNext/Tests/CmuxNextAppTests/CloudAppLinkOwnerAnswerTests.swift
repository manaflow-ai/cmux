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
    private static let key = CloudLinkKey(machine: "vm_aaaaaaaaaaaaaaaaaaaa")

    private static func answer(_ vmKind: String?) -> Data {
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

        // A down, a revoke or a pause ends the answer with its link.
        _ = await link.apply(CloudLinkChange(key: Self.key, state: .down, generation: 3, reason: "eof"))
        #expect(await link.ownerLink == nil)
        _ = try await link.connect(origin: .user)
        #expect(await link.ownerLink != nil)
        await link.end(reason: "paused")
        #expect(await link.ownerLink == nil)
    }

    @Test func aConnectThatDoesNotSayOwnerGivesNoOwnerAnswer() async throws {
        let link = CloudLinkSession(key: Self.key, resolver: Self.resolver(nil))
        _ = try await link.connect(origin: .user)
        #expect(await link.ownerLink == nil)
    }
}
