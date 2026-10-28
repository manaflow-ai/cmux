import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing

/// `AppServices.init` builds and wires, and starts no service; each start is its own launch
/// post (`serviceStartPosts()`). What a control in the first frame needs is wired in init: the updater's
/// card and tip closures, the Restart cmux-tui… binding, and the notifications' app (the Chief pet the
/// launch turn makes, a click's read).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct AppServicesInitStartsTests {
    @Test func initWiresTheFirstFrameControlsAndStartsNoService() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.browserHost == nil, "the browser host is the BrowserHost.start post's")
        #expect(services.input.monitor == nil, "input verification is the InputVerification.start post's")
        #expect(!services.notifications.isStarted, "the banners are the Notifications.start post's")
        #expect(services.notifications.services === services, "the launch turn's Chief pet and a click's read find the app")
        #expect(services.registry.isBound(ActionID(rawValue: "palette.restartServer")),
                "Restart cmux-tui… works from the palette, the CLI and MCP before its observers start")
        #expect(services.updater.runTipAction != nil, "a tip's Try It runs its action from the first frame")
        #expect(services.registry.runObserver != nil, "the person's own runs mark their tips used from the first frame")
        #expect(services.updater.presentUpdateUI != nil && services.updater.openChangelog != nil
                && services.updater.openChangelogSpan != nil && services.updater.openReleaseNotesURL != nil,
                "the Updated card's sheet and links work from the first frame")
    }

    @Test func eachPostStartsItsOwnServiceAtItsDesignPriority() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let posts = services.serviceStartPosts().posts
        #expect(posts.map(\.name.description) == ["SurfaceInvariant.observeWindowOcclusion", "InputVerification.start",
                                                  "Notifications.start", "Updater.attachedWork", "ServerUpdates.start",
                                                  "BrowserHost.start"])
        #expect(posts.map(\.priority) == [.afterFirstFrame, .afterFirstFrame, .afterFirstFrame,
                                          .afterStartup, .afterStartup, .afterStartup])
        let run = { (name: String) in posts.first { $0.name.description == name }?.work() }
        run("BrowserHost.start")
        #expect(services.browserHost != nil, "the BrowserHost.start post builds the host")
        #expect(services.input.monitor == nil && !services.notifications.isStarted, "one post starts one service")
        run("InputVerification.start")
        #expect(services.input.monitor != nil, "the InputVerification.start post makes the monitor")
        run("Notifications.start")
        #expect(services.notifications.isStarted, "the Notifications.start post follows the store")
    }

    /// The store only appends live notifications, and the start now runs after the daemon may have sent
    /// some: one that came before the start arrives, once.
    @Test func aNotificationInTheStoreBeforeTheStartArrivesOnce() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let notifications = services.notifications
        notifications.terminalNotificationsEnabled = { false }  // each arrival writes one log line, no banner
        let store = services.daemon.store
        let notification = { (id: UInt64) throws -> DaemonNotification in
            try JSONDecoder().decode(DaemonNotification.self, from: Data(
                #"{"notification":\#(id),"title":"t","body":"","level":"info","source":"terminal"}"#.utf8))
        }
        store.apply(.notification(try notification(7)))
        notifications.start()
        let arrivals = { (id: UInt64) in notifications.log.filter { $0.hasPrefix("arrived \(id) ") }.count }
        for _ in 0..<200 where arrivals(7) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(arrivals(7) == 1, "the notification sent before the start arrives")
        store.apply(.notification(try notification(8)))
        for _ in 0..<200 where arrivals(8) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(arrivals(8) == 1, "a later one arrives")
        #expect(arrivals(7) == 1, "the first never arrives again")
    }
}
