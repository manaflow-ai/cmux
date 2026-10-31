import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextNowPlaying
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// Check for Updates answers at once (Lawrence 2026-10-19: "I do the command
/// to check for updates and I can't tell if it's being checked for right
/// now or not"). Every path runs the one registered action; the action
/// shows "Checking for Updates…" before it returns (no observation hop, so
/// within the frame); a second request while checking shows the same
/// progress and fetches nothing new; and the check's status takes the
/// bottom-left slot from the Now Playing card instead of waiting behind it.
@MainActor @Suite(.serialized, .closesItsWindows) struct UpdateCheckFeedbackTests {
    /// A feed that holds every fetch until ``release()`` and counts them.
    actor HeldFeed: AppcastFetching {
        private(set) var fetches = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func fetch(_ url: URL) async throws -> Data {
            fetches += 1
            if !released { await withCheckedContinuation { waiters.append($0) } }
            return Data("<rss><channel><title>cmux</title></channel></rss>".utf8)
        }

        func release() {
            released = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    /// A DEV build's updater (the read-only probe; no Sparkle, no defaults of the user's).
    static func updater(feed: HeldFeed) -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.update-check-feedback", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = UserDefaults(suiteName: "UpdateCheckFeedbackTests.\(UUID().uuidString)")!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, prober: UpdateProber(fetcher: feed),
                                     defaults: defaults, enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        updater.start()
        return updater
    }

    /// The registry the menu, palette, CLI (`settings check-for-updates`) and a Ghostty keybind run.
    static func registry(_ updater: UpdaterService) -> ActionRegistry {
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        UpdateHandlers.bind(into: registry, updater: updater)
        return registry
    }

    @Test func everyPathToCheckForUpdatesIsTheOneRegisteredAction() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "palette.checkForUpdates" })
        #expect(descriptor.surfaces.contains(.menu), "the app menu item runs another path")
        #expect(descriptor.surfaces.contains(.palette), "Cmd+Shift+P runs another path")
        #expect(descriptor.cliName == "settings check-for-updates", "the CLI runs another path")
        #expect(TerminalHostActionRoute.route(.checkForUpdates)?.id == "palette.checkForUpdates", "a Ghostty keybind runs another path")
        #expect(ActionCatalog.all.filter { $0.title == descriptor.title }.count == 1, "two actions are called Check for Updates")
    }

    @Test func theActionShowsCheckingBeforeItReturns() async throws {
        let feed = HeldFeed()
        let updater = Self.updater(feed: feed)
        let registry = Self.registry(updater)
        #expect(registry.perform("palette.checkForUpdates", invocation: ActionInvocation(origin: .user)))
        // No await between the run and the read: what shows now is what the next frame draws.
        #expect(updater.card == .checking, "the check gave no feedback when it ran: \(String(describing: updater.card))")
        let notice = try #require(SidebarCardFeed.noticeCard(updater, registry: nil), "the sidebar has no notice for the check")
        #expect(notice.title == UpdaterStrings.checking)
        #expect(notice.progress == .indeterminate, "checking shows no spinner")
        await feed.release()
    }

    @Test func aSecondCheckWhileCheckingShowsTheSameProgressAndFetchesNothingNew() async throws {
        let feed = HeldFeed()
        let updater = Self.updater(feed: feed)
        let registry = Self.registry(updater)
        _ = registry.perform("palette.checkForUpdates", invocation: ActionInvocation(origin: .user))
        let first = SidebarCardFeed.noticeCard(updater, registry: nil)
        _ = registry.perform("palette.checkForUpdates", invocation: ActionInvocation(origin: .user))
        #expect(updater.card == .checking, "a repeated check left \(String(describing: updater.card))")
        #expect(SidebarCardFeed.noticeCard(updater, registry: nil) == first, "a repeated check changed what shows")
        for _ in 0..<50 where await feed.fetches == 0 { await Task.yield() }
        #expect(await feed.fetches == 1, "a repeated check fetched the feed again")
        await feed.release()
    }

    @Test func theResultShowsTheVersionAndWhenItWasChecked() async throws {
        let feed = HeldFeed()
        await feed.release()
        let updater = Self.updater(feed: feed)
        let task = try #require(updater.checkForUpdates(), "a DEV build's check returned no probe")
        #expect(await task.value == nil)
        updater.syncFlowPhase()
        #expect(updater.card == .note(.upToDate))
        let shown = try #require(updater.cardPresentation)
        #expect(shown.title == UpdaterStrings.upToDate)
        #expect(shown.detail == UpdaterStrings.upToDateDetail("1.0.0 (100)"), "up to date does not say the version and when")
    }

    @Test func theCheckStatusTakesTheSlotFromNowPlaying() async throws {
        let feed = HeldFeed()
        let updater = Self.updater(feed: feed)
        updater.checkForUpdates()
        let notice = try #require(SidebarCardFeed.noticeCard(updater, registry: nil), "the check gave no notice")
        _ = NSApplication.shared
        let model = SidebarModel()
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: Metrics.sidebarWidth, height: 640), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: Metrics.sidebarWidth, height: 640)
        defer { window.close() }
        model.nowPlaying = NowPlayingCardTests.track()
        model.noticeCard = notice
        let deadline = ContinuousClock.now + .seconds(5)
        func noticeShows() -> Bool { !sidebar.noticeCardView.isHidden && !sidebar.noticeCardView.frame.isEmpty }
        while !noticeShows(), ContinuousClock.now < deadline {
            await Task.yield()
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
        }
        #expect(noticeShows(), "Checking for Updates is covered by the Now Playing card")
        #expect(sidebar.nowPlayingCardView.isHidden || sidebar.nowPlayingCardView.frame.isEmpty, "two cards share the slot")
        await feed.release()

        // A tip is no answer to anything the person asked: Now Playing keeps the slot from it.
        model.noticeCard = SidebarNoticeCard(id: SidebarCardFeed.tipPrefix + "t", title: "Tip")
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        for _ in 0..<20 { await Task.yield(); sidebar.needsLayout = true; sidebar.layoutSubtreeIfNeeded() }
        #expect(!sidebar.nowPlayingCardView.isHidden && !sidebar.nowPlayingCardView.frame.isEmpty, "a tip pushed Now Playing out")
    }
}
