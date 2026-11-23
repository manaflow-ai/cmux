import AppKit
import CmuxNextDaemon
@testable import CmuxNextNotifications
import CmuxNextSettings
import Testing

/// VoiceOver's line for an agent in another chat (WCAG 2.2 SC 4.1.3): said only when cmux is in front,
/// the chat is not, the policy rings for it and no banner shows; never said twice over a banner.
@Suite
struct AgentStatusAnnouncementTests {
    private static func decide(desktop: DesktopNotificationMode = NotificationPreferences.desktopDefault, appActive: Bool = true,
                               viewed: Bool = false, muted: Bool = false, bannerAllowed: Bool = true) -> NotificationPolicy.Decision {
        var prefs = NotificationPreferences()
        prefs.desktop = desktop
        var arrival = NotificationPolicy.Arrival(source: .agent)
        arrival.appActive = appActive
        arrival.paneIsViewed = viewed
        arrival.workspaceMuted = muted
        arrival.bannerAllowed = bannerAllowed
        return NotificationPolicy(prefs: prefs).decide(arrival)
    }

    @Test func kindsFollowTheAgentsLevelAndOnlyAgentsAreSaid() {
        #expect(AgentStatusAnnouncement.kind(level: .warning, source: "agent") == .needsYou)
        #expect(AgentStatusAnnouncement.kind(level: .error, source: "agent") == .failed)
        #expect(AgentStatusAnnouncement.kind(level: .info, source: "agent") == .finished)
        #expect(AgentStatusAnnouncement.kind(level: .warning, source: "terminal") == nil)
        #expect(AgentStatusAnnouncement.kind(level: .info, source: nil) == nil)
    }

    @Test func saidWhenNoBannerShowsWhileCmuxIsInFront() {
        let whenInactive = Self.decide(desktop: .whenInactive)
        #expect(!whenInactive.desktop)
        #expect(AgentStatusAnnouncement.speaks(whenInactive, bannersDenied: false, appActive: true, paneIsViewed: false))
        let never = Self.decide(desktop: .never)
        #expect(AgentStatusAnnouncement.speaks(never, bannersDenied: false, appActive: true, paneIsViewed: false))
        let noBannerAsked = Self.decide(bannerAllowed: false)
        #expect(AgentStatusAnnouncement.speaks(noBannerAsked, bannersDenied: false, appActive: true, paneIsViewed: false))
    }

    @Test func aBannerThatShowsIsNotSaidAgainButADeniedOneIs() {
        let banner = Self.decide()
        #expect(banner.desktop, "the default posts a banner for a chat not in view")
        #expect(!AgentStatusAnnouncement.speaks(banner, bannersDenied: false, appActive: true, paneIsViewed: false))
        #expect(AgentStatusAnnouncement.speaks(banner, bannersDenied: true, appActive: true, paneIsViewed: false))
    }

    @Test func silentForAViewedPaneAMutedWorkspaceOrCmuxInBack() {
        let viewed = Self.decide(desktop: .never, viewed: true)
        #expect(!AgentStatusAnnouncement.speaks(viewed, bannersDenied: false, appActive: true, paneIsViewed: true))
        let muted = Self.decide(desktop: .never, muted: true)
        #expect(!AgentStatusAnnouncement.speaks(muted, bannersDenied: false, appActive: true, paneIsViewed: false))
        let back = Self.decide(desktop: .never, appActive: false)
        #expect(!AgentStatusAnnouncement.speaks(back, bannersDenied: true, appActive: false, paneIsViewed: false))
    }

    @Test func theLineNamesTheChatUnlessItIsHidden() {
        #expect(AgentStatusAnnouncement.text(.needsYou, name: "build-fix") == "build-fix: Needs you")
        #expect(AgentStatusAnnouncement.text(.finished, name: nil) == "Finished")
        #expect(AgentStatusAnnouncement.text(.failed, name: "") == "Failed")
        #expect(AgentStatusAnnouncement.priority(.finished) == .medium)
        #expect(AgentStatusAnnouncement.priority(.needsYou) == .high)
        #expect(AgentStatusAnnouncement.priority(.failed) == .high)
    }
}
