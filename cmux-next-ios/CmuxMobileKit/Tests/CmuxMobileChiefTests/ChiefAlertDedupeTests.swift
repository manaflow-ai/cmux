import Testing
@testable import CmuxMobileChief

/// One notification per Chief reply: the app's own alert yields to the Mac's
/// push (duplicate Chief notifications on cmux-next iOS, 2026-10-30).
struct ChiefAlertDedupeTests {
    @Test func noLocalAlertWhenTheMacPushesReplies() {
        #expect(!ChiefAlerts.postsLocalAlert(visible: false, appActive: false, muted: false, macPushes: true))
        #expect(!ChiefAlerts.postsLocalAlert(visible: false, appActive: true, muted: false, macPushes: true))
    }

    @Test func localAlertWhenNoPushCoversTheReply() {
        #expect(ChiefAlerts.postsLocalAlert(visible: false, appActive: false, muted: false, macPushes: false))
        #expect(ChiefAlerts.postsLocalAlert(visible: true, appActive: false, muted: false, macPushes: false))
    }

    @Test func noLocalAlertWhenOnScreenOrMuted() {
        #expect(!ChiefAlerts.postsLocalAlert(visible: true, appActive: true, muted: false, macPushes: false))
        #expect(!ChiefAlerts.postsLocalAlert(visible: false, appActive: false, muted: true, macPushes: false))
    }
}
