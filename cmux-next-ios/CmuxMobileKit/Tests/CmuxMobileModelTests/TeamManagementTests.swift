import Foundation
import Testing
@testable import CmuxMobileModel

/// Records requests and answers each with a canned response.
private final class FakeTeamServer: @unchecked Sendable {
    struct Answer {
        var status: Int
        var body: String
        var fails = false
    }

    private let lock = NSLock()
    private var answers: [String: Answer] = [:]
    private var recorded: [URLRequest] = []

    func answer(_ method: String, _ path: String, status: Int = 200, body: String) {
        lock.withLock { answers["\(method) \(path)"] = Answer(status: status, body: body) }
    }

    func failConnection(_ method: String, _ path: String) {
        lock.withLock { answers["\(method) \(path)"] = Answer(status: 0, body: "", fails: true) }
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func client() -> WebTeamClient {
        WebTeamClient(base: URL(string: "https://cmux.example")!, credentials: { ("access-1", "refresh-1") }) { [self] request in
            let key = "\(request.httpMethod ?? "") \(request.url?.path(percentEncoded: true) ?? "")"
            let answer = lock.withLock { () -> Answer? in
                recorded.append(request)
                return answers[key]
            }
            guard let answer, !answer.fails else { throw URLError(.notConnectedToInternet) }
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: nil)!
            return (Data(answer.body.utf8), response)
        }
    }
}

private let adminPermissions = #"{"updateTeam":true,"deleteTeam":true,"inviteMembers":true,"readMembers":true,"removeMembers":true,"manageApiKeys":true,"manageBilling":true}"#
private let memberPermissions = #"{"updateTeam":false,"deleteTeam":false,"inviteMembers":false,"readMembers":true,"removeMembers":false,"manageApiKeys":false,"manageBilling":false}"#

@Suite struct WebTeamClientTests {
    @Test func listsTeamsWithRolesAndSendsBothSessionTokens() async throws {
        let server = FakeTeamServer()
        server.answer("GET", "/api/teams", body: """
        {"teams":[{"id":"t1","displayName":"Manaflow","profileImageUrl":null,"role":"admin","permissions":\(adminPermissions)},
                  {"id":"t2","displayName":"Fleet","profileImageUrl":"https://x/y.png","role":"member","permissions":\(memberPermissions)}],
         "selectedTeamId":"t2"}
        """)
        let directory = try await server.client().listTeams()
        #expect(directory.selectedTeamID == "t2")
        #expect(directory.teams.map(\.accountTeam) == [
            AppStore.AccountTeam(id: "t1", name: "Manaflow", role: .admin),
            AppStore.AccountTeam(id: "t2", name: "Fleet", role: .member),
        ])
        #expect(directory.teams[0].permissions == .all)
        #expect(directory.teams[1].permissions.readMembers && !directory.teams[1].permissions.deleteTeam)
        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(request.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh-1")
    }

    @Test func createsATeamThroughTheWebBackendAsItsAdmin() async throws {
        let server = FakeTeamServer()
        server.answer("POST", "/api/teams", status: 201, body: #"{"team":{"id":"t9","displayName":"New team"}}"#)
        let team = try await server.client().createTeam(named: "New team")
        #expect(team == AppStore.AccountTeam(id: "t9", name: "New team", role: .admin))
        let request = try #require(server.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["displayName": "New team"])
    }

    @Test func readsATeamWithMembersRolesInvitationsAndPlan() async throws {
        let server = FakeTeamServer()
        server.answer("GET", "/api/teams/t1", body: """
        {"team":{"id":"t1","displayName":"Manaflow","profileImageUrl":null},
         "viewer":{"userId":"u-me","role":"admin","permissions":\(adminPermissions)},
         "members":[{"userId":"u-b","displayName":"Bea","email":"bea@x.dev","profileImageUrl":null,"role":"member","isViewer":false},
                    {"userId":"u-a","displayName":null,"email":"zed@x.dev","profileImageUrl":null,"role":"admin","isViewer":false},
                    {"userId":"u-me","displayName":"Me","email":"me@x.dev","profileImageUrl":null,"role":"admin","isViewer":true}],
         "invitations":[{"id":"i1","email":"sam@x.dev","role":"member","expiresAt":"2026-11-01T10:00:00.000Z"}],
         "links":[],
         "billing":{"planId":"pro","seats":null,"memberLimit":5,"memberCount":3,"hasActiveSubscription":false}}
        """)
        let detail = try await server.client().team(id: "t1")
        #expect(detail.name == "Manaflow")
        #expect(detail.role == .admin && detail.canRename && detail.canDelete)
        // You first, then admins, then by name; a member with no name shows its email.
        #expect(detail.members.map(\.id) == ["u-me", "u-a", "u-b"])
        #expect(detail.members[0].isYou && detail.members[1].name == "zed@x.dev")
        #expect(detail.members.map(\.role) == [.admin, .admin, .member])
        #expect(detail.invitations.first?.email == "sam@x.dev")
        #expect(detail.invitations.first?.expiresAt == ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z"))
        #expect(detail.billing?.planTitle == "Pro")
        #expect(detail.billing?.memberCountText == "3 of 5")
    }

    @Test func aMemberReadsTheTeamWithoutAdminActions() async throws {
        let server = FakeTeamServer()
        server.answer("GET", "/api/teams/t2", body: """
        {"team":{"id":"t2","displayName":"Fleet","profileImageUrl":null},
         "viewer":{"userId":"u-me","role":"member","permissions":\(memberPermissions)},
         "members":[{"userId":"u-me","displayName":"Me","email":null,"profileImageUrl":null,"role":"member","isViewer":true}],
         "invitations":[],"links":[],
         "billing":{"planId":null,"seats":null,"memberLimit":null,"memberCount":1,"hasActiveSubscription":false}}
        """)
        let detail = try await server.client().team(id: "t2")
        #expect(detail.role == .member)
        #expect(!detail.canRename && !detail.canDelete)
        #expect(detail.billing?.planTitle == nil)
        #expect(detail.billing?.memberCountText == "1")
    }

    @Test func renamesAndDeletesWithTheTeamIdAsOnePathSegment() async throws {
        let server = FakeTeamServer()
        server.answer("PATCH", "/api/teams/a%2Fb", body: #"{"team":{"id":"a/b","displayName":"Renamed","profileImageUrl":null}}"#)
        server.answer("DELETE", "/api/teams/a%2Fb", body: #"{"ok":true}"#)
        let client = server.client()
        #expect(try await client.renameTeam(id: "a/b", to: "Renamed") == "Renamed")
        try await client.deleteTeam(id: "a/b")
        #expect(server.requests.map(\.httpMethod) == ["PATCH", "DELETE"])
        let body = try JSONSerialization.jsonObject(with: try #require(server.requests[0].httpBody)) as? [String: String]
        #expect(body == ["displayName": "Renamed"])
    }

    @Test func errorsCarryTheServerCodeOrSayUnreachable() async throws {
        let server = FakeTeamServer()
        server.answer("DELETE", "/api/teams/t1", status: 409,
                      body: #"{"error":{"code":"team_has_active_subscription","message":"Cancel the team subscription before deleting the team."}}"#)
        server.answer("PATCH", "/api/teams/t2", status: 403, body: #"{"error":{"code":"forbidden","message":"You do not have permission to do this."}}"#)
        server.answer("GET", "/api/teams/gone", status: 404, body: #"{"error":{"code":"team_not_found","message":"Team not found."}}"#)
        // A server without the route (an HTML 404) or a gateway error is the same as no answer.
        server.answer("GET", "/api/teams", status: 404, body: "<html>Not found</html>")
        server.answer("GET", "/api/teams/t3", status: 502, body: "<html>Bad gateway</html>")
        server.failConnection("POST", "/api/teams")
        let client = server.client()
        await #expect(throws: TeamServiceError.server(status: 409, code: "team_has_active_subscription",
                                                      message: "Cancel the team subscription before deleting the team.")) {
            try await client.deleteTeam(id: "t1")
        }
        await #expect(throws: TeamServiceError.server(status: 403, code: "forbidden", message: "You do not have permission to do this.")) {
            _ = try await client.renameTeam(id: "t2", to: "x")
        }
        await #expect(throws: TeamServiceError.server(status: 404, code: "team_not_found", message: "Team not found.")) {
            _ = try await client.team(id: "gone")
        }
        await #expect(throws: TeamServiceError.unreachable) { _ = try await client.listTeams() }
        await #expect(throws: TeamServiceError.unreachable) { _ = try await client.team(id: "t3") }
        await #expect(throws: TeamServiceError.unreachable) { _ = try await client.createTeam(named: "x") }
        server.answer("GET", "/api/teams", body: #"{"teams":"nope"}"#)
        await #expect(throws: TeamServiceError.malformed) { _ = try await client.listTeams() }
    }

    @Test func userMessagesNameTheReasonNeverTheDeveloperText() {
        let billing = TeamServiceError.server(status: 409, code: "team_has_active_subscription", message: "Cancel the team subscription before deleting the team.")
        #expect(TeamServiceError.message(for: billing, action: .delete).contains("active subscription"))
        #expect(TeamServiceError.message(for: TeamServiceError.server(status: 403, code: "forbidden", message: "x"), action: .rename)
            == "Only team admins can do this.")
        #expect(TeamServiceError.message(for: TeamServiceError.unreachable, action: .create).hasPrefix("Couldn't reach cmux"))
        #expect(TeamServiceError.message(for: URLError(.badServerResponse), action: .delete) == "Couldn't delete the team.")
    }
}

/// A team API fake for the page model.
private actor FakeTeamService: TeamManaging {
    var detail: TeamDetail
    var deleteError: TeamServiceError?
    private(set) var calls: [String] = []

    init(detail: TeamDetail, deleteError: TeamServiceError? = nil) {
        self.detail = detail
        self.deleteError = deleteError
    }

    func team(id: String) async throws -> TeamDetail {
        calls.append("get \(id)")
        return detail
    }

    func renameTeam(id: String, to name: String) async throws -> String {
        calls.append("rename \(id) \(name)")
        detail.name = name
        return name
    }

    func deleteTeam(id: String) async throws {
        calls.append("delete \(id)")
        if let deleteError { throw deleteError }
    }
}

private func team(role: TeamRole?) -> TeamDetail {
    TeamDetail(id: "t1", name: "Manaflow", role: role, permissions: role == .admin ? .all : .none, members: [
        TeamDetail.Member(id: "me", name: "Me", role: role, isYou: true),
    ])
}

@MainActor @Suite struct TeamDetailModelTests {
    @Test func anAdminRenamesAndTheOwnerHearsTheNewName() async {
        let service = FakeTeamService(detail: team(role: .admin))
        let model = TeamDetailModel(teamID: "t1", service: service)
        var renamed: [String] = []
        model.onRenamed = { id, name in renamed.append("\(id)=\(name)") }
        await model.load()
        #expect(model.detail?.canRename == true)
        #expect(await model.rename(to: "  Manaflow Labs "))
        #expect(model.detail?.name == "Manaflow Labs")
        #expect(renamed == ["t1=Manaflow Labs"])
        // The same name, or an empty one, sends nothing.
        #expect(!(await model.rename(to: "Manaflow Labs")))
        #expect(!(await model.rename(to: "  ")))
        #expect(await service.calls == ["get t1", "rename t1 Manaflow Labs"])
    }

    @Test func anAdminDeletesAndTheOwnerHearsIt() async {
        let service = FakeTeamService(detail: team(role: .admin))
        let model = TeamDetailModel(teamID: "t1", service: service)
        var deleted: [String] = []
        model.onDeleted = { deleted.append($0) }
        await model.load()
        #expect(await model.delete())
        #expect(deleted == ["t1"])
        #expect(model.actionError == nil)
    }

    @Test func aMemberCannotRenameOrDeleteAndNothingIsSent() async {
        let service = FakeTeamService(detail: team(role: .member))
        let model = TeamDetailModel(teamID: "t1", service: service)
        model.onDeleted = { _ in Issue.record("a member's page deleted the team") }
        await model.load()
        #expect(model.detail?.canRename == false && model.detail?.canDelete == false)
        #expect(!(await model.rename(to: "Other")))
        #expect(!(await model.delete()))
        #expect(await service.calls == ["get t1"])
    }

    @Test func aTeamWithoutRolesOffersNoAdminActions() async {
        let model = TeamDetailModel(teamID: "t1", service: FakeTeamService(detail: team(role: nil)))
        await model.load()
        #expect(model.detail?.canDelete == false)
        #expect(!(await model.delete()))
    }

    @Test func aBillingRefusalKeepsTheTeamAndSaysWhy() async {
        let refusal = TeamServiceError.server(status: 409, code: "team_has_active_subscription", message: "")
        let service = FakeTeamService(detail: team(role: .admin), deleteError: refusal)
        let model = TeamDetailModel(teamID: "t1", service: service)
        model.onDeleted = { _ in Issue.record("a refused delete was reported as done") }
        await model.load()
        #expect(!(await model.delete()))
        #expect(model.actionError?.contains("active subscription") == true)
        #expect(model.detail?.name == "Manaflow")
        #expect(!model.isWorking)
    }
}

@MainActor @Suite struct TeamDeletionFallbackTests {
    private func store(_ teams: [Team], active: String) -> AppStore {
        let store = AppStore.mock()
        store.teams = teams
        store.activeTeamID = active
        return store
    }

    @Test func deletingTheActiveTeamMovesToAnotherTeamBeforeThePersonalSpace() {
        let store = store([Team(id: "personal-u", name: "Personal"), Team(id: "a", name: "A", role: .admin),
                           Team(id: "b", name: "B", role: .member)], active: "a")
        let next = store.teamsAfterDeleting("a")
        #expect(next.teams.map(\.id) == ["personal-u", "b"])
        #expect(next.teams.last?.role == .member)
        #expect(next.selectedID == "b")
    }

    @Test func deletingTheLastTeamMovesToThePersonalSpace() {
        let withPersonal = store([Team(id: "a", name: "A"), Team(id: "personal-u", name: "Personal")], active: "a")
        #expect(withPersonal.teamsAfterDeleting("a").selectedID == "personal-u")
        // No personal space listed yet: nothing to select (the live coordinator adds it).
        let alone = store([Team(id: "a", name: "A")], active: "a")
        let next = alone.teamsAfterDeleting("a")
        #expect(next.teams.isEmpty && next.selectedID == nil)
    }

    @Test func deletingAnotherTeamKeepsTheActiveOne() {
        let store = store([Team(id: "a", name: "A"), Team(id: "b", name: "B")], active: "b")
        let next = store.teamsAfterDeleting("a")
        #expect(next.teams == [AppStore.AccountTeam(id: "b", name: "B")])
        #expect(next.selectedID == "b")
    }

    @Test func aRenameShowsAtOnce() {
        let store = store([Team(id: "a", name: "A", role: .admin)], active: "a")
        store.renameTeam("a", to: "A2")
        #expect(store.teams.first?.name == "A2")
        #expect(store.teams.first?.role == .admin)
    }

    @Test func liveTeamsKeepTheirRoles() {
        let store = store([], active: "")
        store.applyLiveTeams([AppStore.AccountTeam(id: "a", name: "A", role: .admin), AppStore.AccountTeam(id: "b", name: "B")], selectedID: "a")
        #expect(store.teams.map(\.role) == [.admin, nil])
        // A list without roles (the sign-in service) keeps the role already known.
        store.applyLiveTeams([AppStore.AccountTeam(id: "a", name: "A")], selectedID: "a")
        #expect(store.teams.first?.role == .admin)
    }
}

@Suite struct TeamListRoleTests {
    @Test func theSignInServicesListKeepsTheFetchedRoles() {
        var state = TeamListState()
        state.fetched([AppStore.AccountTeam(id: "a", name: "A", role: .admin), AppStore.AccountTeam(id: "b", name: "B", role: .member)])
        state.published([AppStore.AccountTeam(id: "a", name: "A renamed"), AppStore.AccountTeam(id: "c", name: "C")])
        #expect(state.teams == [AppStore.AccountTeam(id: "a", name: "A renamed", role: .admin), AppStore.AccountTeam(id: "c", name: "C")])
    }
}
