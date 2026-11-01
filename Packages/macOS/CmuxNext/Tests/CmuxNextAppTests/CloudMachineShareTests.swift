import CMUXAuthCore
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextCloud
import Foundation
import Testing

/// Share Machine… and Share with Me (CloudMachineShare.swift): the classic chat-grants routes
/// (web/app/api/vm/[id]/chat-grants), the page's rows, and the refusals keyed on the API's code.
@Suite(.serialized)
struct CloudMachineShareTests {
    nonisolated final class GrantsAPI: URLProtocol {
        nonisolated(unsafe) static var seen: [(method: String, path: String)] = []
        /// The status and body the next request answers.
        nonisolated(unsafe) static var answer: (Int, String) = (200, "{}")

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            Self.seen.append((request.httpMethod ?? "", URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""))
            let (status, body) = Self.answer
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func api() -> CloudAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrantsAPI.self]
        return CloudAPIClient(baseURL: URL(string: "https://cloud.standin.invalid") ?? URL(fileURLWithPath: "/dev/null"),
                              tokens: { ("access", "refresh") }, teamID: { "team_a" },
                              session: URLSession(configuration: configuration), appVersion: "test")
    }

    @Test func listsGrantsAndChangesThemOnTheClassicRoutes() async throws {
        GrantsAPI.seen = []
        GrantsAPI.answer = (200, #"{"grants":[{"userId":"user-b","grantedBy":"user-a","createdAt":"2026-10-31T10:00:00.000Z"}]}"#)
        let grants = try await api().chatGrants("vm 1")
        #expect(grants == [CloudChatGrant(userId: "user-b", grantedBy: "user-a", createdAt: "2026-10-31T10:00:00.000Z")])
        GrantsAPI.answer = (200, #"{"grant":{"userId":"user-b","grantedBy":"user-a","createdAt":"x"}}"#)
        try await api().grantChat("vm 1", to: "user/b")
        GrantsAPI.answer = (200, #"{"revoked":true}"#)
        #expect(try await api().revokeChat("vm 1", from: "user-b"))
        #expect(GrantsAPI.seen.map(\.method) == ["GET", "PUT", "DELETE"])
        // Ids are one path segment each: a slash in one never reaches another route.
        #expect(GrantsAPI.seen.map(\.path) == ["/api/vm/vm%201/chat-grants", "/api/vm/vm%201/chat-grants/user%2Fb", "/api/vm/vm%201/chat-grants/user-b"])
    }

    @Test func currentChatStartAccessReadsOnlyTheCurrentRoleWithoutAnAttach() async throws {
        GrantsAPI.seen = []
        GrantsAPI.answer = (200, #"{"chatStart":"granted"}"#)
        #expect(try await api().chatStartAccess("vm 1") == .granted)
        #expect(GrantsAPI.seen.map(\.method) == ["GET"])
        #expect(GrantsAPI.seen.map(\.path) == ["/api/vm/vm%201/chat-start-access"])

        // A revoked grant on the same machine immediately reads as no app-start authority.
        GrantsAPI.answer = (200, #"{"chatStart":"none"}"#)
        #expect(try await api().chatStartAccess("vm 1") == .none)
    }

    @Test func aRefusalKeepsTheServersCode() async throws {
        GrantsAPI.answer = (403, #"{"error":"vm_chat_share_forbidden","message":"Only the machine's creator or a team admin can share chats on it."}"#)
        do {
            try await api().grantChat("vm-1", to: "user-b")
            Issue.record("the grant should be refused")
        } catch {
            guard case .refused(let code, let message) = CloudMachineShare.refusal(error) else {
                Issue.record("not refused")
                return
            }
            #expect(code == "vm_chat_share_forbidden")
            #expect(message == CloudShareStrings.refusal(.forbidden))
        }
    }

    @Test(arguments: [
        ("vm_chat_share_forbidden", CloudMachineShareRefusal.forbidden),
        ("vm_chat_grants_personal_machine", .personalMachine),
        ("vm_chat_grants_unavailable", .unavailable),
        ("vm_chat_grant_not_member", .notMember),
    ])
    func refusalsRoundTripTheirCode(code: String, refusal: CloudMachineShareRefusal) {
        #expect(CloudMachineShareRefusal(code: code) == refusal)
        #expect(refusal.code == code)
    }

    @Test func otherCodesAreNoShareRefusal() {
        #expect(CloudMachineShareRefusal(code: nil) == nil)
        #expect(CloudMachineShareRefusal(code: "vm_not_found") == nil)
    }

    private func member(_ id: String, _ name: String?, _ email: String?, role: CMUXTeamRole = .member) -> CMUXTeamDetail.Member {
        CMUXTeamDetail.Member(userId: id, displayName: name, email: email, role: role, isViewer: false)
    }

    @Test func theRosterListsTeammatesButTheCreatorSharedFirst() {
        let roster = CloudMachineShareRoster(
            members: [member("creator", "Cy", nil), member("u-z", "Zoe", "zoe@x.test"), member("u-a", nil, "ada@x.test"), member("u-b", "Bo", "bo@x.test")],
            viewer: CMUXTeamDetail.Viewer(userId: "creator", role: .member, permissions: CMUXTeamPermissions()),
            creator: "creator",
            grants: [CloudChatGrant(userId: "u-z", grantedBy: "creator", createdAt: ""),
                     CloudChatGrant(userId: "gone", grantedBy: "creator", createdAt: "")])
        #expect(roster.rows.map(\.userID) == ["gone", "u-z", "u-a", "u-b"])
        #expect(roster.rows.map(\.shared) == [true, true, false, false])
        // An email-only member reads as the email, with no second line repeating it.
        #expect(roster.rows[2].name == "ada@x.test")
        #expect(roster.rows[2].email == nil)
        #expect(roster.rows[1].email == "zoe@x.test")
        #expect(roster.canShare)
    }

    @Test func onlyTheCreatorOrAnAdminMayShare() {
        let viewer = { (role: CMUXTeamRole) in CMUXTeamDetail.Viewer(userId: "me", role: role, permissions: CMUXTeamPermissions()) }
        #expect(!CloudMachineShareRoster(members: [], viewer: viewer(.member), creator: "someone", grants: []).canShare)
        #expect(CloudMachineShareRoster(members: [], viewer: viewer(.admin), creator: "someone", grants: []).canShare)
    }
}
