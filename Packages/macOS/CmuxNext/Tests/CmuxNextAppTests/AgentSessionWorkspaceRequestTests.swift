import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextDaemon
import Foundation
import Testing

/// `agent.openSessionWorkspace`'s arguments (`AgentSessionWorkspaceRequest`): read as the handler
/// opens them, and refused before anything opens.
struct AgentSessionWorkspaceRequestTests {
    static func request(_ arguments: [String: ActionValue]) throws -> AgentSessionWorkspaceRequest {
        try AgentSessionWorkspaceRequest(ActionInvocation(arguments: arguments, origin: .script), sessionRequired: "no session")
    }

    @Test func everyArgumentIsReadAsGiven() throws {
        let key = "0D3C6F2A-8B1E-4C7D-9A5F-1E2B3C4D5E6F"
        let request = try Self.request([
            "session": .string("  s-1 \n"), "name": .string("lane"), "defaultName": .string(" cx-lane "), "key": .string(key),
            "cwd": .string("/tmp"), "host": .string("chief:h1"), "group": .string(" GUI push "), "placement": .string("top"),
        ])
        #expect(request.session == "s-1", "the session id is trimmed")
        #expect(request.name == "lane")
        #expect(request.defaultName == " cx-lane ", "a default name is kept as given")
        #expect(request.key.rawValue == key.lowercased(), "the caller's key is the workspace key, lowercased")
        #expect(request.cwd == "/tmp")
        #expect(request.host == "chief:h1")
        #expect(request.group == " GUI push ", "the group is looked up as given")
        #expect(request.top)
    }

    @Test func emptyArgumentsAreAbsentAndAKeyThatIsNoUUIDGetsAFreshOne() throws {
        let request = try Self.request([
            "session": .string("s-2"), "name": .string(""), "defaultName": .string(" \n"), "key": .string("not-a-uuid"),
            "cwd": .string(""), "host": .string(""), "group": .string(""), "placement": .string(""),
        ])
        #expect(request.name == nil)
        #expect(request.defaultName == nil, "a blank default name is no default name")
        #expect(request.cwd == nil)
        #expect(request.host == nil)
        #expect(request.group == nil)
        #expect(!request.top)
        #expect(request.key.rawValue != "not-a-uuid")
        #expect(UUID(uuidString: request.key.rawValue) != nil && request.key.rawValue == request.key.rawValue.lowercased())
        #expect(try !Self.request(["session": .string("s-3")]).top, "no placement is not top")
    }

    /// The refusal text `arguments` get, nil when they open.
    static func refusal(_ arguments: [String: ActionValue]) -> String? {
        do {
            _ = try request(arguments)
            return nil
        } catch {
            return (error as? AgentSessionWorkspaceRequest.Refusal)?.description ?? "not a Refusal: \(error)"
        }
    }

    @Test func noSessionABadGroupOrABadPlacementIsRefused() {
        #expect(Self.refusal(["session": .string(" \t"), "group": .string("GUI push")]) == "no session", "no session is refused first")
        let group = "agent.openSessionWorkspace: group must be a non-empty human label, not a cmux id; omit group or use a label such as \"GUI push\""
        for id in ["ws_1234", "grp_abc", "0D3C6F2A-8B1E-4C7D-9A5F-1E2B3C4D5E6F", "   "] {
            #expect(Self.refusal(["session": .string("s-4"), "group": .string(id), "placement": .string("bottom")]) == group, "\(id)")
        }
        #expect(Self.refusal(["session": .string("s-5"), "placement": .string("bottom")])
            == "agent.openSessionWorkspace: placement must be top; omit it for the workspaces.newPlacement setting")
        #expect(Self.refusal(["session": .string("s-6"), "group": .string("GUI push"), "placement": .string("top")]) == nil)
    }
}
