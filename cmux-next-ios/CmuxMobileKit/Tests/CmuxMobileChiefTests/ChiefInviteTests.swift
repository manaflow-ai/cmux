import Foundation
import Testing
@testable import CmuxMobileChief

/// Invite to cmux (the Chief header's trailing button): the share sheet's
/// note and link. The link is the public site, never a TestFlight or a
/// tracking link.
@Suite struct ChiefInviteTests {
    @Test func theLinkIsThePublicSite() {
        #expect(ChiefInvite.url.absoluteString == "https://cmux.com")
        #expect(!ChiefInvite.url.absoluteString.localizedCaseInsensitiveContains("testflight"))
        #expect(ChiefInvite.url.query == nil)
    }

    @Test func theNoteIsShortAndNamesCmux() {
        #expect(ChiefInvite.message == "I'm using cmux to run my coding agents from my phone. Try it:")
        #expect(ChiefInvite.actionTitle == "Invite to cmux")
        #expect(ChiefInvite.symbol == "person.badge.plus")
    }

    @Test func thePreviewCarriesTheLinkAndName() {
        let icon = NSItemProvider()
        let metadata = ChiefInvite.metadata(icon: icon)
        #expect(metadata.url == ChiefInvite.url)
        #expect(metadata.originalURL == ChiefInvite.url)
        #expect(metadata.title == "cmux")
        #expect(metadata.iconProvider === icon)
    }
}
