#if os(iOS)
import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// Home's New Message lists and resolves people as the Mac's does
/// (`HomeRecipientField`, `HomeNewMessageDraft`).
@MainActor
@Suite struct HomeNewMessageDirectoryTests {
    static func chief(_ id: String, _ name: String, _ detail: String, _ kind: HomeRecipientEntry.Kind, activity: Date? = nil) -> HomeRecipientEntry {
        HomeRecipientEntry(contact: ConversationContact(id: id, name: name, initials: "C", colorHex: "#636366", handles: [], detail: detail),
                           kind: kind, activity: activity)
    }

    static let atlas = chief("chief:cloud", "Atlas", "Chief · Main · Cloud", .chief(.cloud))
    static let macChief = chief("chief:mac", "Chief", "Chief · Studio", .chief(.mac))
    static let builder = chief("chief:mac:b", "Builder", "Chief · Studio",
                               .macChief(MacConversationRoute(conversationID: "b", chief: "agent_b", title: "Builder")))
    static let ada = HomeNewMessageDirectory.teammate(id: "user_ada", name: "Ada Lovelace")
    static let grace = HomeNewMessageDirectory.teammate(id: "user_grace", name: "Grace Hopper")

    static func directory(team: [HomeRecipientEntry] = [ada, grace], teamName: String? = "Manaflow",
                          canCreateChief: Bool = true) -> HomeNewMessageDirectory {
        HomeNewMessageDirectory(snapshot: HomeRecipientSnapshot(
            chiefs: [atlas, macChief, builder], team: team, agentTabs: [], teamName: teamName,
            canCreateChief: canCreateChief, canInvite: true, openCloudChiefAgent: "agent_atlas"
        ), cloud: nil, me: "user_me")
    }

    @Test func beforeTypingTheChiefsLeadWithNewChiefThenTheTeam() {
        let rows = Self.directory().idleRows(excluding: [])
        #expect(rows == [
            .header("Chiefs"), .contact(Self.atlas.contact), .contact(Self.macChief.contact), .contact(Self.builder.contact),
            .action(HomeNewMessageDirectory.newChiefAction),
            .header("Team"), .contact(Self.ada.contact), .contact(Self.grace.contact),
        ])
    }

    @Test func aTeamOfOneShowsInviteAndChosenPeopleLeaveTheList() {
        let rows = Self.directory(team: [], canCreateChief: false).idleRows(excluding: ["chief:mac"])
        #expect(rows == [
            .header("Chiefs"), .contact(Self.atlas.contact), .contact(Self.builder.contact),
            .header("Team"), .action(HomeNewMessageDirectory.inviteAction),
        ])
    }

    @Test func anUnreadTeamShowsNoTeamSectionAndAddressesTakeTheServiceColor() async throws {
        let directory = Self.directory(team: [])
        var snapshot = directory.snapshot
        snapshot.teamUnread = true
        directory.update(snapshot)
        #expect(!directory.idleRows(excluding: []).contains(.header("Team")), "a failed read is not a team of one")
        let found = try await directory.searchContacts("ada@example.com", limit: 20, excluding: [])
        #expect(found.first?.tintsWithService == true, "a typed address row is tinted as Messages tints it")
        #expect(Self.ada.contact.tintsWithService == false, "a teammate's Team line stays secondary")
    }

    @Test func typedTextFindsWordStartsBeforeNamesThatContainIt() async throws {
        let directory = Self.directory()
        // "ho": Grace *Ho*pper starts a word; nobody else contains it.
        #expect(try await directory.searchContacts("ho", limit: 20, excluding: []).map(\.id) == ["team:user_grace"])
        // "b": only Builder has a word starting with it.
        let found = try await directory.searchContacts("b", limit: 20, excluding: [])
        #expect(found.map(\.id) == ["chief:mac:b"])
        #expect(try await directory.searchContacts("ada", limit: 20, excluding: ["team:user_ada"]).isEmpty, "chosen people are left out")
    }

    @Test func aTypedEmailComesFirstWithInviteToTheTeamAfterIt() async throws {
        let directory = Self.directory()
        let found = try await directory.searchContacts("ada@example.com", limit: 20, excluding: [])
        #expect(found.first?.id == "address:ada@example.com")
        #expect(found.first?.detail == "Email")
        let rows = directory.typedRows(matches: found, query: "ada@example.com")
        guard rows.count >= 2, case let .action(action) = rows[1] else {
            Issue.record("no invite row after the address: \(rows)")
            return
        }
        #expect(action.id == "inviteToTeam:ada@example.com")
        #expect(action.title == "Invite ada@example.com to Manaflow")
        #expect(Self.directory(teamName: nil).typedRows(matches: found, query: "ada@example.com").count == found.count,
                "no team to invite to: no invite row")
    }

    @Test func returnResolvesAnAddressAnExactNameOrTheOnlyPrefixElseRed() {
        let directory = Self.directory()
        #expect(directory.resolve("ada@example.com")?.kind == .address("ada@example.com", isEmail: true))
        #expect(directory.resolve("+1 (555) 123-4567")?.kind == .address("+15551234567", isEmail: false))
        #expect(directory.resolve("atlas")?.contact.id == "chief:cloud")
        #expect(directory.resolve("Gra")?.contact.id == "team:user_grace")
        #expect(directory.resolve("zz") == nil, "names nobody: a red token")
    }

    @Test func rowsThatReadAlikeGetTheirLastActivityThenANumber() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = Self.chief("a", "Chief", "Chief · Cloud", .chief(.cloud), activity: now.addingTimeInterval(-7200))
        let b = Self.chief("b", "Chief", "Chief · Cloud", .cloudChief(agentID: "x", conversation: "y"))
        let c = Self.chief("c", "Builder", "Chief · Studio", .chief(.mac))
        let lines = HomeNewMessageDirectory.withLines([a, b, c], now: now).map(\.contact.detail)
        #expect(lines[0]?.hasPrefix("Chief · Cloud · Active ") == true)
        #expect(lines[1] == "Chief · Cloud · No messages yet")
        #expect(lines[2] == "Chief · Studio", "a row unlike any other keeps its line")
        // Still alike after the activity (both new): the second gets a number, as on the Mac.
        let d = Self.chief("d", "Ops", "Chief · Cloud", .cloudChief(agentID: "d", conversation: "d"))
        let e = Self.chief("e", "Ops", "Chief · Cloud", .cloudChief(agentID: "e", conversation: "e"))
        let twins = HomeNewMessageDirectory.withLines([d, e], now: now).map(\.contact.detail)
        #expect(twins == ["Chief · Cloud · No messages yet", "Chief · Cloud · No messages yet · 2"])
    }

    @Test func teamMembersComeFromTheCloudListWithoutThisAccount() throws {
        let data = try JSONSerialization.data(withJSONObject: ["members": [
            ["user": "me", "display_name": "Me"], ["user": "zed", "display_name": "Zed"], ["user": "amy", "display_name": ""],
            ["user": "zed", "display_name": "Zed again"],
        ]])
        let team = HomeNewMessageDirectory.teammates(from: data, excluding: "user_me")
        #expect(team.map(\.contact.name) == ["amy", "Zed"])
        #expect(team.map(\.kind) == [.teammate(participant: "user_amy"), .teammate(participant: "user_zed")])
    }

    @Test func aGroupNamesTheCreatorByItsCloudIDMasksInviteesAndReplaysOnRetry() async throws {
        let directory = Self.directory()
        var calls: [(op: String, params: [String: any Sendable], key: String)] = []
        var failInvite = true
        directory.mutate = { op, params, key in
            calls.append((op, params, key))
            if op == "invite.create", failInvite { throw HomeNewMessageDirectory.refusal("network") }
            return try JSONSerialization.data(withJSONObject: ["conversation": ["id": "conv_g"]])
        }
        _ = try await directory.searchContacts("new@example.com", limit: 20, excluding: [])
        let refs: [ConversationRecipientRef] = [.participant("team:user_ada"), .participant("address:new@example.com")]
        await #expect(throws: ConversationBackendError.self) { try await directory.createConversation(refs) }
        failInvite = false
        let created = try await directory.createConversation(refs)
        #expect(created.info.id == "cloud:conv_g")
        let creates = calls.filter { $0.op == "conversation.create" }
        #expect(creates.count == 2)
        #expect(creates[0].key == creates[1].key, "Send again replays the same group")
        let records = creates[0].params["participants"] as? [[String: any Sendable]] ?? []
        #expect(records.first?["id"] as? String == "user_me", "the creator is this account's Cloud id")
        let invite = calls.last { $0.op == "invite.create" }
        #expect(invite?.params["display_name"] as? String == "n***@example.com", "the group sees the invitee masked")
    }

    @Test func aChiefWhoseConversationCannotOpenIsRefusedUnderTo() async throws {
        let directory = Self.directory()
        directory.prepare = { _ in throw HomeNewMessageDirectory.refusal("Your Mac isn't connected.") }
        await #expect(throws: ConversationBackendError.self) { try await directory.createConversation([.participant("chief:mac:b")]) }
    }

    @Test func maskingAndCloudIDsMatchTheMac() {
        #expect(HomeNewMessageDirectory.masked("ada@example.com", isEmail: true) == "a***@example.com")
        #expect(HomeNewMessageDirectory.masked("+15551234567", isEmail: false) == "+1 *** *** 4567")
        #expect(HomeNewMessageDirectory.masked("12345", isEmail: false) == "***")
        // The Worker's userIdFor / stackTeamIdFor: sha256, 20 hex digits.
        let user = CloudIDs.user(project: "p", stackUser: "u")
        #expect(user.hasPrefix("user_") && user.count == 25 && user != "user_u")
        #expect(CloudIDs.team(project: "p", stackTeam: "T") == CloudIDs.team(project: "p", stackTeam: "t"), "team ids ignore case")
    }

    @Test func oneChiefOpensItsOwnConversationAndMacChiefsCannotJoinAGroup() async throws {
        let directory = Self.directory()
        let opened = try await directory.createConversation([.participant("chief:mac:b")])
        #expect(opened.info.id == "chief:mac:b")
        #expect(opened.created == false)
        await #expect(throws: ConversationBackendError.self) {
            try await directory.createConversation([.participant("chief:mac"), .participant("team:user_ada")])
        }
    }
}
#endif
