import CmuxNextDaemonService
import CmuxNextCloud
import Testing

/// Every team list (the account menu, Switch Active Team, the menu bar) tells the person's own
/// team from a shared one by icon and second line, and names a plan only when the team has one.
/// Leo, 2026-11-09, of Switch Active Team: "what is this?"
@MainActor
struct TeamRowTextTests {
    @Test func thePersonalTeamReadsAsTheEmailWithAPersonIcon() {
        let text = TeamRowText(ActiveTeam.Row(id: "p", title: "Personal", kind: .personal, active: false), email: "ada@example.com")
        #expect(text.symbol == "person")
        #expect(text.subtitle == "ada@example.com")
        let noEmail = TeamRowText(ActiveTeam.Row(id: "p", title: "Personal", kind: .personal, active: false), email: nil)
        #expect(noEmail.subtitle == "Personal")
    }

    @Test func aSharedTeamReadsAsTeamWithItsPlanWhenItHasOne() {
        let planned = TeamRowText(ActiveTeam.Row(id: "t", title: "cmux", kind: .team, active: true, plan: "pro"), email: "ada@example.com")
        #expect(planned.symbol == "person.2")
        #expect(planned.subtitle == "Team · Pro plan")
        let bare = TeamRowText(ActiveTeam.Row(id: "t", title: "cmux", kind: .team, active: false), email: nil)
        #expect(bare.subtitle == "Team")
    }
}
