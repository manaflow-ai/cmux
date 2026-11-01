import AppKit
@testable import CmuxNextApp
import CmuxNextActions
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import Foundation
import Testing
import CmuxNextTestSupport

/// The Update Ready card's Hide button (Lawrence 2026-10-20, cmux NEXT: "clicking Hide does
/// nothing"). The card's highlights popup opens while the pointer is on the card, in the app's one
/// hover card window, which takes clicks for the popup's links. That window keeps a clear band
/// around the card (the shadow and the slide's room) that reaches over the card's top right
/// corner, where Hide sits: the window server gives the click to the popup's window, which found
/// no view there and dropped it. Hide must hide this version's card (kept across a relaunch) until
/// a newer version or a check the person asks for; the card fades out, at once under Reduce Motion.
@MainActor @Suite(.closesItsWindows, .serialized) struct UpdateCardHideTests {
    /// The highlights page, as the App's React surface reports it.
    final class Highlights: SidebarSurfaceIsland {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        var contentHeight: CGFloat = 120
        var onHeightChange: (() -> Void)?
        var onAction: (() -> Void)?
        var onDismiss: (() -> Void)?
        func close() {}
    }

    /// A feed that offers nothing (a check the person asks for reads it).
    struct EmptyFeed: AppcastFetching {
        func fetch(_ url: URL) async throws -> Data { Data("<rss><channel><title>cmux</title></channel></rss>".utf8) }
    }

    static let version = "1.0.0-nightly.3845050428001"
    static let newer = "1.0.0-nightly.3845050428002"

    /// A DEV build's updater on `defaults` (no Sparkle, none of the user's defaults).
    static func updater(defaults: UserDefaults) -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.update-card-hide", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, prober: UpdateProber(fetcher: EmptyFeed()),
                                     defaults: defaults, enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        updater.start()
        return updater
    }

    static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "UpdateCardHideTests.\(UUID().uuidString)")!
    }

    struct Harness {
        let updater: UpdaterService
        let defaults: UserDefaults
        let sidebar: SidebarView
        let window: NSWindow
        let feed: Task<Void, Never>
        var card: SidebarUpdateCardView { sidebar.updateCardView }

        /// Lays the sidebar out until `condition` holds (it follows the model on a task).
        func wait(within timeout: Duration = .seconds(10), until condition: () -> Bool) async {
            let deadline = ContinuousClock.now + timeout
            while !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
                sidebar.needsLayout = true
                sidebar.layoutSubtreeIfNeeded()
            }
        }

        func close() {
            let popup = card.hoverCards()?.cardWindow
            card.hideNotes()
            feed.cancel()
            window.close()
            popup?.closeAfterTest()
        }
    }

    /// The sidebar in a window, its card fed from a staged update, its intents sent where the
    /// App sends them (`SidebarCardFeed`).
    func make(reduceMotion: Bool = false) async throws -> Harness {
        _ = NSApplication.shared
        let defaults = Self.defaults()
        let updater = Self.updater(defaults: defaults)
        updater.debugStage(version: Self.version, notes: .debugFake(version: Self.version, changes: 3))
        let model = SidebarModel()
        model.onIntent = { intent in
            if case .noticeAction(let card, let action) = intent {
                SidebarCardFeed.noticeAction(card, action, updater: updater, open: { _ in })
            }
        }
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.updateCardView.motionPolicy = { MotionPolicy(speed: .fast, reduceMotion: reduceMotion) }
        let width = Metrics.sidebarWidth
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: width, height: 640), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 640)
        let feed = SidebarCardFeed.start(model: model, updater: updater)
        let harness = Harness(updater: updater, defaults: defaults, sidebar: sidebar, window: window, feed: feed)
        await harness.wait { !harness.card.isHidden && harness.card.card != nil }
        return harness
    }

    /// A left click at `screen`, delivered as the window server does: to the frontmost window
    /// there that takes mouse events.
    func click(at screen: NSPoint, windows: [NSWindow]) throws -> NSWindow {
        let target = try #require(windows.first { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(screen) },
                                  "no window takes a click at \(screen)")
        let location = target.convertPoint(fromScreen: screen)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            target.sendEvent(event)
        }
        return target
    }

    @Test func hideHidesTheCardWhileItsHighlightsPopupIsOpen() async throws {
        let h = try await make()
        defer { h.close() }
        try #require(h.updater.readyCard != nil, "the staged update shows no card")
        h.window.orderFront(nil)
        h.card.highlights = Highlights()
        // The pointer on the card opens the popup; it is open when the pointer reaches Hide.
        h.card.showNotes()
        let popup = try #require(h.card.notesPanel, "the highlights popup did not open")
        let hide = h.card.closeButton
        try #require(!hide.isHidden, "the card has no Hide button")
        let center = hide.convert(NSPoint(x: hide.bounds.midX, y: hide.bounds.midY), to: nil)
        let point = h.window.convertPoint(toScreen: center)
        #expect(popup.frame.contains(point), "setup: the popup's window \(popup.frame) does not reach Hide at \(point)")

        let target = try click(at: point, windows: [popup, h.window])

        #expect(h.updater.readyCard == nil, "Hide did nothing: the click at \(point) went to \(type(of: target)) and was lost")
        #expect(UpdateSnooze(defaults: h.defaults).closedVersion == Self.version, "Hide did not keep this version hidden")
        await h.wait { h.card.isHidden }
        #expect(h.card.isHidden, "the card still shows after Hide")
    }

    @Test func hideKeepsThisVersionHiddenUntilANewerOneOrACheck() async throws {
        let defaults = Self.defaults()
        let updater = Self.updater(defaults: defaults)
        updater.debugStage(version: Self.version, notes: nil)
        try #require(updater.readyCard != nil)
        SidebarCardFeed.noticeAction(SidebarUpdateCard.cardID, UpdaterService.updateHideAction, updater: updater, open: { _ in })
        #expect(updater.readyCard == nil, "Hide did not hide the card")

        // A relaunch keeps it hidden.
        let relaunched = Self.updater(defaults: defaults)
        relaunched.debugStage(version: Self.version, notes: nil)
        #expect(relaunched.readyCard == nil, "the hidden card came back after a relaunch")

        // A newer version shows again.
        relaunched.debugStage(version: Self.newer, notes: nil)
        #expect(relaunched.readyCard != nil, "a newer version stayed hidden")

        // Check for Updates (the menu, the palette, the CLI: one action) shows the hidden update.
        relaunched.debugStage(version: Self.version, notes: nil)
        #expect(relaunched.readyCard == nil)
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        UpdateHandlers.bind(into: registry, updater: relaunched)
        #expect(registry.perform("palette.checkForUpdates", invocation: ActionInvocation(origin: .user)))
        #expect(relaunched.readyCard != nil, "Check for Updates did not show the hidden update")
    }

    @Test func hideUnderReduceMotionHidesTheCardAtOnce() async throws {
        let h = try await make(reduceMotion: true)
        defer { h.close() }
        h.window.orderFront(nil)
        h.card.layoutSubtreeIfNeeded()
        h.card.closeButton.press()
        await h.wait { h.card.card == nil }
        try #require(h.card.card == nil, "Hide did not take the card away")
        #expect(h.card.isHidden && !h.card.isLeaving, "under Reduce Motion the card faded out instead of going at once")
    }
}
