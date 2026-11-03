import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextPopups
import Foundation
import os
import Testing

/// A sign-in window through its host seam (``WebAuthHost``): the page comes
/// from the host in the request's profile, every end (the callback, Escape,
/// the system cancelling, no page) closes the window and its page once and
/// answers the request once, and links out go to the host. Panels are
/// recorded, not ordered in: the suite never activates the test process.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct WebAuthSessionWindowTests {
    private let callbackURL = URL(string: "https://app.example.com/done?code=42")!
    private let host = FakeWebAuthHost()
    private let profiles = OffTheRecordProfiles()
    private let panels = FakePanelPresenter()
    private let brokers = HeldBrokers()

    private nonisolated struct NoChromiumPage: Error {}

    /// Keeps each test's broker for the whole test, as the app does
    /// (AppDelegate -> handler -> broker): a sign-in window holds its broker
    /// weakly, and the windows do not hold it.
    private final class HeldBrokers {
        var all: [WebAuthSessionBroker] = []
    }

    /// The sign-in windows (the broker's opener) and the broker serving `request`.
    private func begin(_ request: FakeWebAuthRequest) -> (WebAuthSessionWindows, WebAuthSessionBroker) {
        let panels = panels
        let windows = WebAuthSessionWindows(
            host: host, logger: Logger(subsystem: "com.cmuxterm.tests", category: "webauth"),
            profiles: profiles, signInCallbacks: CEFSignInCallbacks(), contextMenus: BrowserContextMenuBuilder(),
            activeLook: nil, present: { panels.present($0, $1) }
        )
        let broker = WebAuthSessionBroker(opener: windows)
        brokers.all.append(broker)
        broker.begin(request)
        return (windows, broker)
    }

    /// The request's page once its window shows it (the window loads the start page last).
    private func shownPage(_ request: FakeWebAuthRequest) async throws -> MockBrowserTab {
        await awaitObserved { host.pages.first?.commands.contains(.load(request.url)) == true }
        return try #require(host.pages.first)
    }

    @Test func aSignInLoadsItsStartPageInTheDefaultProfileAndItsCallbackEndsIt() async throws {
        let request = FakeWebAuthRequest()
        let (windows, _) = begin(request)
        let page = try await shownPage(request)
        #expect(page.profileID == .default, "a person already signed in stays signed in")
        #expect(profiles.active.isEmpty)
        #expect(windows.windows[request.id] != nil)
        #expect(panels.presented.map { $0.intent } == [.focus], "the sign-in panel comes forward focused, once")
        #expect(panels.presented.first?.window is BrowserPopupWindow)
        page.load(callbackURL)
        await awaitObserved { request.completions > 0 }
        #expect(request.completedURL == callbackURL)
        #expect(request.completions == 1)
        #expect(request.cancels == 0)
        #expect(page.isClosed)
        #expect(windows.windows.isEmpty)
        #expect(host.links.isEmpty)
    }

    @Test func escapeCancelsAnEphemeralSignInAndEndsItsOffTheRecordProfile() async throws {
        let request = FakeWebAuthRequest(isEphemeral: true)
        let (windows, _) = begin(request)
        let page = try await shownPage(request)
        let profile = page.profileID
        #expect(profile != .default)
        #expect(profiles.contains(profile), "the page runs in its own off-the-record profile")
        page.emit(.unhandledEscape)
        #expect(request.cancels == 1)
        #expect(request.completions == 0)
        #expect(page.isClosed)
        #expect(!profiles.contains(profile), "the profile ends with the window")
        #expect(profiles.isOffTheRecord(profile))
        #expect(windows.windows.isEmpty)
    }

    @Test func aLinkOutOpensThroughTheHostAndTheCallbackInANewTabEndsTheSession() async throws {
        let request = FakeWebAuthRequest()
        let (windows, _) = begin(request)
        let page = try await shownPage(request)
        let terms = URL(string: "https://accounts.example.com/terms")!
        page.emit(.openURL(terms, .foregroundTab))
        #expect(host.links == [terms])
        #expect(request.completions == 0)
        #expect(!page.isClosed)
        page.emit(.openURL(callbackURL, .foregroundTab))
        #expect(request.completedURL == callbackURL)
        #expect(host.links == [terms], "the callback never opens as a tab")
        #expect(page.isClosed)
        #expect(windows.windows.isEmpty)
    }

    @Test func aSignInPagesOwnPopupsClose() async throws {
        let request = FakeWebAuthRequest()
        let (windows, broker) = begin(request)
        let page = try await shownPage(request)
        let engine = MockBrowserEngine(kind: .cef)
        let popup = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://accounts.example.com/popup")))
        let adopted = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://accounts.example.com/new")))
        page.emit(.openPopup(popup, BrowserPopupRequest(size: CGSize(width: 300, height: 200))))
        page.emit(.adoptTab(adopted, .foregroundTab))
        #expect(popup.isClosed)
        #expect(adopted.isClosed)
        #expect(!page.isClosed, "the sign-in goes on")
        #expect(request.cancels == 0)
        broker.systemCancelled(request.id)
        #expect(windows.windows.isEmpty)
    }

    @Test func theSystemCancellingClosesTheWindowAndAnswersNothing() async throws {
        let request = FakeWebAuthRequest(isEphemeral: true)
        let (windows, broker) = begin(request)
        let page = try await shownPage(request)
        broker.systemCancelled(request.id)
        #expect(page.isClosed)
        #expect(windows.windows.isEmpty)
        #expect(request.cancels == 0, "the requesting app already ended it")
        #expect(request.completions == 0)
        #expect(!profiles.contains(page.profileID))
    }

    @Test func noChromiumPageCancelsTheSignInAndEndsItsProfile() async throws {
        host.failure = NoChromiumPage()
        let request = FakeWebAuthRequest(isEphemeral: true)
        let (windows, _) = begin(request)
        await awaitObserved { request.cancels > 0 }
        #expect(request.cancels == 1)
        #expect(request.completions == 0)
        #expect(windows.windows.isEmpty)
        let profile = try #require(host.configurations.first?.profile)
        #expect(profile != .default)
        #expect(!profiles.contains(profile))
    }

    @Test func aPageThatArrivesAfterItsWindowEndedClosesUnloaded() async throws {
        host.holdsPages = true
        let request = FakeWebAuthRequest()
        let (windows, broker) = begin(request)
        await awaitObserved { host.waiting == 1 }
        broker.systemCancelled(request.id)
        #expect(windows.windows.isEmpty)
        host.releasePages()
        await awaitObserved { host.pages.first?.isClosed == true }
        let page = try #require(host.pages.first)
        #expect(!page.commands.contains(.load(request.url)), "an ended sign-in loads nothing")
        #expect(request.cancels == 0)
        #expect(request.completions == 0)
    }
}
