import Foundation
import Testing
@testable import CmuxNextBrowser

/// "when we open up google meet inside our browser, it works well" (Leo, 2026-11-22). In a Chromium
/// tab Notification.requestPermission() always read `default`: the request ended unanswered because
/// a Chromium tab showed no notification (Lawrence, 2026-11-11: no refusal stored against a later
/// notification feature). Now the prompt bar asks, and an allowed site's notifications reach cmux's
/// banner through a page-world wrapper and a media-world relay (`BrowserWebNotificationScript`).
@Suite struct CEFWebNotificationTests {
    @Test func aNotificationRequestAsksTheNotificationsQuestion() {
        #expect(CEFPermissionPrompts.notifications == 1 << 15)
        #expect(CEFPermissionPrompts.kind(of: CEFPermissionPrompts.notifications) == .notifications)
    }

    /// The answer is stored for the site like WebKit's, so a reload does not ask again.
    @Test func notificationsHaveASiteSetting() {
        #expect(!BrowserPermissionKind.notifications.siteKinds.isEmpty)
    }

    @Test func aPostedNotificationParses() {
        let posted = BrowserWebNotificationScript.posted(json: #"{"id":"abc-1","title":"Ana joined","body":"Weekly sync"}"#)
        #expect(posted == .init(id: "abc-1", title: "Ana joined", body: "Weekly sync"))
        #expect(BrowserWebNotificationScript.posted(json: #"{"id":"abc-2","title":"No body"}"#)?.body == "")
    }

    /// The payload comes from the page: anything else is dropped and long text is cut.
    @Test func anUntrustedPayloadIsBounded() {
        #expect(BrowserWebNotificationScript.posted(json: "not json") == nil)
        #expect(BrowserWebNotificationScript.posted(json: #"{"title":"no id"}"#) == nil)
        #expect(BrowserWebNotificationScript.posted(json: #"{"id":"","title":"t"}"#) == nil)
        let longID = String(repeating: "i", count: 65)
        #expect(BrowserWebNotificationScript.posted(json: #"{"id":"\#(longID)","title":"t"}"#) == nil)
        let long = String(repeating: "x", count: 5000)
        let cut = BrowserWebNotificationScript.posted(json: #"{"id":"a","title":"\#(long)","body":"\#(long)"}"#)
        #expect(cut?.title.count == BrowserWebNotificationScript.maxTextLength)
        #expect(cut?.body.count == BrowserWebNotificationScript.maxTextLength)
    }

    /// A banner click names the notification as a JSON string, so an id cannot break out of the call.
    @Test func theClickScriptQuotesTheID() {
        #expect(BrowserWebNotificationScript.clickScript(id: "abc-1") == #"window.__cmuxWebNotificationClick?.(["abc-1"][0])"#)
        let hostile = BrowserWebNotificationScript.clickScript(id: #"x"]);alert(1);(["#)
        #expect(hostile.hasPrefix(#"window.__cmuxWebNotificationClick?.(["x\"]);alert(1);([\""#))
    }

    @Test func theBannerNamesTheSite() {
        #expect(BrowserWebNotificationScript.site(of: "https://meet.google.com") == "meet.google.com")
        #expect(BrowserWebNotificationScript.site(of: "http://127.0.0.1:8080") == "127.0.0.1:8080")
    }

    /// Only the main frame's notifications pass, as in WebKit tabs and Chrome.
    @Test func theChannelTakesTheMainFrameOnly() {
        let name = BrowserWebNotificationScript.channel
        #expect(CEFPageMessage(channel: name, payload: "{}", mainFrame: true)?.channel == .webNotification)
        #expect(CEFPageMessage(channel: name, payload: "{}", mainFrame: false) == nil)
        #expect(CEFPageMessage.Channel.webNotification.world == BrowserMediaState.world)
    }

    /// Both install paths carry the wrapper (page world) and its relay (media world), main frame only,
    /// and the relay posts on the notification channel.
    @Test func bothInstallPathsCarryTheWrapperAndRelay() {
        for post in [CEFDocumentScripts.Post.binding, .pageChannel] {
            let media = CEFDocumentScripts(post: post).media
            let wrapper = media.first { $0.source == BrowserWebNotificationScript.pageScript }
            #expect(wrapper?.world == "")
            #expect(wrapper?.allFrames == false)
            let relay = media.first { $0.source.contains(BrowserWebNotificationScript.event) && $0.world == BrowserMediaState.world }
            #expect(relay?.allFrames == false)
            #expect(relay?.source.contains(post.send(BrowserWebNotificationScript.channel, "report")) == true)
        }
    }
}
