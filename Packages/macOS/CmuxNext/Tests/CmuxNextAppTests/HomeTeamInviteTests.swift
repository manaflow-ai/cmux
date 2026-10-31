import AppKit
import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextTestSupport
import Testing

/// The user, 2026-10-29: "need easier way to invite people to my team from the chief UI". Invite to
/// Team is one step from Home (its menu, the palette, and an email typed into New Message's To:),
/// and its dialog shows what a join costs the team before Send can go.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeTeamInviteTests {
    @Test func aJoinOnAPaidTeamPlanIsAPaidSeat() {
        #expect(HomeTeamSeatImpact.of(canInvite: true, planID: "team", hasSubscription: true, memberCount: 4, memberLimit: nil)
            == .paidSeat(members: 4))
        #expect(HomeTeamSeatImpact.of(canInvite: true, planID: "pro", hasSubscription: true, memberCount: 2, memberLimit: 3)
            == .capped(members: 2, limit: 3))
        #expect(HomeTeamSeatImpact.of(canInvite: true, planID: nil, hasSubscription: false, memberCount: 1, memberLimit: nil)
            == .free(members: 1))
        #expect(HomeTeamSeatImpact.of(canInvite: false, planID: "team", hasSubscription: true, memberCount: 4, memberLimit: nil)
            == .notAllowed)
        #expect(!HomeTeamSeatImpact.notAllowed.allowsSending)
    }

    @Test func aTypedEmailOffersInviteToTheActiveTeamUnderIt() throws {
        let field = HomeRecipientField(frame: NSRect(x: 0, y: 0, width: 480, height: 44))
        field.contacts = { [] }
        field.inviteTeam = { "cmux" }
        var invited: [ContactAddress] = []
        field.onInviteToTeam = { invited.append($0) }
        field.text.stringValue = "leo@cmux.com"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field.text))

        let rows = field.suggestions.rows
        let address = try #require(ContactAddress.parse("leo@cmux.com"))
        #expect(rows.contains(.inviteToTeam(address, team: "cmux")))
        let invite = try #require(rows.firstIndex(of: .inviteToTeam(address, team: "cmux")))
        #expect(rows.firstIndex(of: .recipient(.address(address))).map { $0 < invite } ?? true, "the invite row comes after the address")
        field.suggestions.activate(rows[invite])
        #expect(invited == [address])
        invited.removeAll()

        // Signed out or no team: no row.
        field.inviteTeam = { nil }
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field.text))
        #expect(!field.suggestions.rows.contains { if case .inviteToTeam = $0 { true } else { false } })
        #expect(invited.isEmpty)
    }

    @Test func sendWaitsForTheSeatLineThenSendsTheAddressOnce() async throws {
        let window = Self.window()
        defer { Self.close(window) }
        let (impacts, giveImpact) = AsyncStream<HomeTeamSeatImpact>.makeStream()
        let sheet = HomeTeamInviteSheet(team: "cmux", prefill: "leo@cmux.com")
        sheet.seatImpact = {
            for await impact in impacts { return impact }
            return .unknown
        }
        var sent: [String] = []
        sheet.onSend = { address in
            sent.append(address.description)
            return .invited(nil)
        }
        var finished = 0
        sheet.onFinish = { _ in finished += 1 }
        HomeSheetPresenter().present(sheet, over: window)

        #expect(!sheet.primaryButton.isEnabled, "Send went before the person saw what a join costs")
        giveImpact.yield(.paidSeat(members: 4))
        giveImpact.finish()
        for _ in 0..<1_000 where sheet.impact == nil { await Task.yield() }
        #expect(sheet.impact == .paidSeat(members: 4))
        #expect(sheet.impactLabel.stringValue == HomeConversationStrings.seatImpact(.paidSeat(members: 4)))
        #expect(sheet.primaryButton.isEnabled)

        sheet.primaryButton.performClick(nil)
        for _ in 0..<1_000 where finished == 0 { await Task.yield() }
        #expect(sent == ["leo@cmux.com"])
        #expect(finished == 1)
        #expect(WindowOverlayHost.existingHost(for: window)?.presentedHandles.isEmpty ?? true, "a sent invite left the dialog up")
    }

    @Test func aTeamThatRefusesThisPersonsInvitesNeverEnablesSend() async {
        let window = Self.window()
        defer { Self.close(window) }
        let sheet = HomeTeamInviteSheet(team: "cmux", prefill: "leo@cmux.com")
        sheet.seatImpact = { .notAllowed }
        var sent = 0
        sheet.onSend = { _ in sent += 1; return .invited(nil) }
        HomeSheetPresenter().present(sheet, over: window)
        for _ in 0..<1_000 where sheet.impact == nil { await Task.yield() }
        #expect(sheet.impact == .notAllowed)
        #expect(!sheet.primaryButton.isEnabled)
        sheet.cancel(nil)
        #expect(sent == 0)
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private static func close(_ window: NSWindow) {
        let panel = WindowOverlayHost.existingHost(for: window)?.panel
        window.close()
        panel?.close()
    }
}
