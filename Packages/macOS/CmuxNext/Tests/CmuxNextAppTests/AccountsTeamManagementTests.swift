import CmuxNextAccounts
import CmuxNextCloud
import Testing

/// Settings > Accounts, Teams: each team with the person's role, a team's
/// details (admin and member), and create, rename and delete as the page
/// sends them (`team.*` gestures) against the demo services, which answer
/// like the cmux team API.
@MainActor
@Suite struct AccountsTeamManagementTests {
    private func run(_ model: AccountsModel, _ action: String, team: String? = nil, name: String? = nil) async throws -> String? {
        let gesture = try #require(AccountsPageAction(action: action, provider: nil, account: nil, secret: nil, team: team, name: name))
        return await model.perform(gesture)
    }

    private func loaded(_ services: MockAccountsServices = MockAccountsServices()) async -> AccountsModel {
        let model = AccountsModel(services: services)
        await model.teamsModel.reload()
        return model
    }

    private func row(_ model: AccountsModel, _ id: String) throws -> AccountsPageState.TeamRow {
        try #require(model.pageState.teamList?.rows.first { $0.id == id })
    }

    @Test func eachTeamShowsYourRoleAndTheActiveOne() async throws {
        let model = await loaded()
        let list = try #require(model.pageState.teamList)
        #expect(list.rows.map(\.name) == ["Personal", "Acme"])
        #expect(list.rows.map(\.role) == ["Admin", "Member"])
        #expect(list.rows.map(\.active) == ["Active", nil])
        #expect(list.rows.allSatisfy { !$0.open && $0.detail == nil })
        #expect(list.newTeam.id == "team.new")
    }

    @Test func rolesShowAsUnknownWhenOnlyTheSignInServiceAnswers() async throws {
        let services = MockAccountsServices()
        services.rolesUnknown = true
        let model = await loaded(services)
        #expect(model.pageState.teamList?.rows.map(\.roleKind) == ["unknown", "unknown"])
        #expect(model.pageState.teamList?.rows.first?.role == "Role unknown")
    }

    @Test func signedOutShowsNoTeams() async throws {
        let services = MockAccountsServices()
        services.isSignedInToCmux = false
        #expect(await loaded(services).pageState.teamList == nil)
    }

    @Test func anAdminSeesMembersInvitationsRenameAndDelete() async throws {
        let model = await loaded()
        _ = try await run(model, "team.details", team: "team-personal")
        let team = try row(model, "team-personal")
        #expect(team.open)
        #expect(team.toggle.title == "Hide Details")
        let detail = try #require(team.detail)
        #expect(detail.facts.first?.label == "Your role")
        #expect(detail.facts.first?.value == "Admin")
        #expect(detail.facts.contains { $0.label == "Plan" && $0.value == "Free" })
        #expect(detail.members.map(\.name) == ["Demo User"])
        #expect(detail.members.first?.you == "You")
        #expect(detail.members.first?.detail == "demo@example.com")
        #expect(detail.invitations?.map(\.email) == ["grace@example.com"])
        #expect(detail.invitations?.first?.expires?.hasPrefix("Expires ") == true)
        #expect(detail.buttons.map(\.id) == ["team.rename", "team.delete"])
        #expect(detail.buttons.last?.destructive == true)
        #expect(detail.readOnly == nil)
        // Details closes again.
        _ = try await run(model, "team.details", team: "team-personal")
        #expect(try row(model, "team-personal").detail == nil)
    }

    @Test func aMemberSeesTheTeamReadOnly() async throws {
        let model = await loaded()
        _ = try await run(model, "team.details", team: "team-acme")
        let detail = try #require(try row(model, "team-acme").detail)
        #expect(detail.facts.first?.value == "Member")
        #expect(detail.members.map(\.role) == ["Member", "Admin"])
        #expect(detail.members.map(\.you) == ["You", nil])
        #expect(detail.invitations == nil)
        #expect(detail.buttons.isEmpty)
        #expect(detail.readOnly == "Only team admins can rename or delete this team.")
    }

    /// The server lets only admins rename, delete or list invitations: a member
    /// whose permissions say otherwise still sees the team read-only.
    @Test func aMemberWithEditPermissionsStillSeesItReadOnly() async throws {
        let services = MockAccountsServices()
        services.permissiveMemberTeamIDs = ["team-acme"]
        let model = await loaded(services)
        _ = try await run(model, "team.details", team: "team-acme")
        let detail = try #require(try row(model, "team-acme").detail)
        #expect(detail.buttons.isEmpty)
        #expect(detail.invitations == nil)
        #expect(detail.readOnly != nil)
    }

    @Test func renamingValidatesTheNameThenRenamesEverywhere() async throws {
        let model = await loaded()
        _ = try await run(model, "team.details", team: "team-personal")
        _ = try await run(model, "team.rename", team: "team-personal")
        let form = try #require(try row(model, "team-personal").detail?.rename)
        #expect(form.value == "Personal")
        #expect(form.maxLength == 64)

        let refused = try await run(model, "team.saveName", team: "team-personal", name: "   ")
        #expect(refused == "Enter a team name of 1 to 64 characters.")
        #expect(try row(model, "team-personal").detail?.rename?.error == refused)
        #expect(try await run(model, "team.saveName", team: "team-personal", name: String(repeating: "x", count: 65)) != nil)

        #expect(try await run(model, "team.saveName", team: "team-personal", name: "  Research  ") == nil)
        let renamed = try row(model, "team-personal")
        #expect(renamed.name == "Research")
        #expect(renamed.detail?.rename == nil)
        #expect(model.pageState.teams?.options.first?.name == "Research") // the Active Team menu follows
        #expect(model.pageState.teamList?.notice?.text == "Renamed the team to “Research”.")
    }

    @Test func deletingTheActiveTeamAsksFirstThenMovesToAnother() async throws {
        let services = MockAccountsServices()
        let model = await loaded(services)
        _ = try await run(model, "team.details", team: "team-personal")
        _ = try await run(model, "team.delete", team: "team-personal")
        let confirm = try #require(try row(model, "team-personal").detail?.confirm)
        #expect(confirm.text.contains("“Personal”"))
        #expect(services.activeTeam?.teams.count == 2) // nothing deleted before the confirmation

        #expect(try await run(model, "team.confirmDelete", team: "team-personal") == nil)
        #expect(model.pageState.teamList?.rows.map(\.id) == ["team-acme"])
        #expect(services.activeTeam?.id == "team-acme")
        #expect(model.pageState.teamList?.rows.first?.active == "Active")
        #expect(model.pageState.teamList?.notice?.text == "Deleted “Personal”. “Acme” is now your active team.")
    }

    @Test func cancellingTheConfirmationDeletesNothing() async throws {
        let services = MockAccountsServices()
        let model = await loaded(services)
        _ = try await run(model, "team.details", team: "team-personal")
        _ = try await run(model, "team.delete", team: "team-personal")
        _ = try await run(model, "team.cancel")
        #expect(try row(model, "team-personal").detail?.confirm == nil)
        #expect(services.calls.contains { $0.hasPrefix("deleteTeam") } == false)
    }

    @Test func aSubscriptionBlocksDeleteWithAClearMessage() async throws {
        let services = MockAccountsServices()
        services.subscribedTeamIDs = ["team-personal"]
        let model = await loaded(services)
        _ = try await run(model, "team.details", team: "team-personal")
        #expect(try row(model, "team-personal").detail?.facts.contains { $0.label == "Plan" && $0.value == "Team" } == true)
        _ = try await run(model, "team.delete", team: "team-personal")

        let refused = try await run(model, "team.confirmDelete", team: "team-personal")

        #expect(refused == "This team has an active subscription. Cancel it in Billing, then delete the team.")
        #expect(try row(model, "team-personal").detail?.confirm?.error == refused)
        #expect(services.activeTeam?.id == "team-personal")
    }

    @Test func aMemberCannotDeleteEvenIfThePageAsks() async throws {
        let services = MockAccountsServices()
        let model = await loaded(services)
        let refused = try await run(model, "team.confirmDelete", team: "team-acme")
        #expect(refused == "Only team admins can do this.")
        #expect(services.activeTeam?.teams.map(\.id) == ["team-personal", "team-acme"])
    }

    @Test func creatingATeamMakesYouItsAdminAndSelectsIt() async throws {
        let services = MockAccountsServices()
        let model = await loaded(services)
        _ = try await run(model, "team.new")
        let form = try #require(model.pageState.teamList?.create)
        #expect(form.kind == "create")
        #expect(form.value.isEmpty)

        #expect(try await run(model, "team.create", name: "") != nil)
        #expect(model.pageState.teamList?.create?.error != nil)

        #expect(try await run(model, "team.create", name: "Design") == nil)
        let list = try #require(model.pageState.teamList)
        #expect(list.create == nil)
        let created = try #require(list.rows.last)
        #expect(created.name == "Design")
        #expect(created.role == "Admin")
        #expect(created.active == "Active")
        #expect(services.activeTeam?.team?.displayName == "Design")
    }

    @Test func teamGesturesNeedTheirFields() {
        #expect(AccountsPageAction(action: "team.details", provider: nil, account: nil, secret: nil) == nil)
        #expect(AccountsPageAction(action: "team.saveName", provider: nil, account: nil, secret: nil, team: "t") == nil)
        #expect(AccountsPageAction(action: "team.create", provider: nil, account: nil, secret: nil) == nil)
        #expect(AccountsPageAction(action: "team.bogus", provider: nil, account: nil, secret: nil) == nil)
        #expect(AccountsPageAction(action: "team.new", provider: nil, account: nil, secret: nil) == .team(.new))
    }
}
