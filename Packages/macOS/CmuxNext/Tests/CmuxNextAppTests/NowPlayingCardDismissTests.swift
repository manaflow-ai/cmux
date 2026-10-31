import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextNowPlaying
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Observation
import Testing

/// The bottom-left media card can be put away without a trip to Settings (Lawrence 2026-10-19,
/// u2437): hovering it shows an x, the x hides it until other media starts, and a right-click
/// offers Hide, Hide Until Relaunch, Never Show Media Card (`sidebar.nowPlaying.enabled` off) and
/// Play/Pause. Every row and the x run one registered action, which the palette, the CLI and MCP
/// reach too; Show Media Card brings the card back.
@MainActor @Suite(.serialized, .closesItsWindows) struct NowPlayingCardDismissTests {
    @Observable final class FakeSource: NowPlayingSource {
        var nowPlaying: SidebarNowPlaying?
        @ObservationIgnored var commands: [SidebarNowPlayingCommand] = []
        func perform(_ command: SidebarNowPlayingCommand) { commands.append(command) }
    }

    static let labels = SidebarNowPlaying.Labels(play: "Play", pause: "Pause", previous: "Previous Track", next: "Next Track")

    static func track(_ title: String = "Weightless", playing: Bool = true) -> SidebarNowPlaying {
        SidebarNowPlaying(title: title, artist: "Marconi Union", isPlaying: playing, position: 60, duration: 480,
                          canPrevious: true, canNext: true, labels: labels)
    }

    struct Harness {
        let services: AppServices
        let source: FakeSource
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        let url: URL
        let feed: Task<Void, Never>
        var card: SidebarNowPlayingCardView { sidebar.nowPlayingCardView }
        var cardIsShown: Bool { !card.isHidden && !card.frame.isEmpty }

        /// `sidebar.nowPlaying.enabled` as cmux.json holds it now.
        func savedEnabled() -> Bool? {
            guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return ((root["sidebar"] as? [String: Any])?["nowPlaying"] as? [String: Any])?["enabled"] as? Bool
        }

        /// Waits for `condition` up to a deadline: the feed, the settings write and the reload run on tasks.
        func until(_ condition: () -> Bool, within timeout: Duration = .seconds(10)) async {
            let deadline = ContinuousClock.now + timeout
            while !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
                sidebar.needsLayout = true
                sidebar.layoutSubtreeIfNeeded()
            }
        }

        /// The menu a right-click on the card's middle opens, as AppKit asks the hit view and then its superviews.
        func rightClickCard() -> NSMenu? {
            sidebar.layoutSubtreeIfNeeded()
            let point = NSPoint(x: card.frame.midX, y: card.frame.minY + 6)
            let location = sidebar.convert(point, to: nil)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let superview = sidebar.superview else { return nil }
            var view = sidebar.hitTest(superview.convert(point, from: sidebar))
            while let current = view {
                if let menu = current.menu(for: event) { return menu }
                view = current === sidebar ? nil : current.superview
            }
            return nil
        }

        func tearDown() {
            feed.cancel()
            window.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    func make() async throws -> Harness {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-now-playing-dismiss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"sidebar":{"nowPlaying":{"enabled":true}}}"#.utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let design = DesignSettings()
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: design, fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()

        let source = FakeSource()
        source.nowPlaying = Self.track()
        let model = SidebarModel()
        // The sidebar's card intents take the App's route (SidebarBridge sends them the same way).
        model.onIntent = { intent in
            if case .nowPlaying(let command) = intent { source.perform(command) } else { SidebarCardFeed.handle(intent, services: services) }
        }
        let sidebar = SidebarView(model: model, design: design)
        sidebar.contextMenuProvider = { target in
            SidebarContextMenus.menu(for: target, model: model, services: services, scope: ThemeScope(level: .room))
        }
        let width = Metrics.sidebarWidth
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: width, height: 640), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 640)
        window.orderFrontRegardless()
        let feed = model.followNowPlaying(source, dismissal: services.cache.pageRequests.nowPlayingCard) { [weak services] in
            services?.settings?.snapshot.nowPlaying.enabled ?? false
        }
        let h = Harness(services: services, source: source, model: model, sidebar: sidebar, window: window, url: url, feed: feed)
        await h.until { h.cardIsShown }
        return h
    }

    static func titles(_ menu: NSMenu?) -> [String] {
        (menu?.items ?? []).flatMap { [$0.title] + titles($0.submenu) }.filter { !$0.isEmpty }
    }

    @Test func hoveringTheCardRevealsItsCloseButton() async throws {
        let h = try await make()
        defer { h.tearDown() }
        try #require(h.cardIsShown, "no media card while a track plays")
        #expect(h.card.closeButton.isHidden || h.card.closeButton.alphaValue == 0, "the x shows before the pointer is on the card")
        h.card.setHovered(true)
        #expect(!h.card.closeButton.isHidden && h.card.closeButton.alphaValue == 1, "hovering the card does not show its x")
        #expect(h.card.bounds.contains(h.card.closeButton.frame) && !h.card.closeButton.frame.isEmpty, "the x \(h.card.closeButton.frame) is not on the card")
        #expect(h.card.closeButton.frame.minX > h.card.bounds.midX && h.card.closeButton.frame.minY < h.card.bounds.midY,
                "the x \(h.card.closeButton.frame) is not at the card's top right")
        #expect(h.card.closeButton.accessibilityLabel()?.isEmpty == false, "the x has no VoiceOver label")
        h.card.setHovered(false)
        // Gone either way: faded to 0, or hidden at once when the hover fade is instant (Reduce
        // Motion, process-wide and set by suites that run alongside).
        #expect(h.card.closeButton.isHidden || h.card.closeButton.alphaValue == 0, "the x stays after the pointer leaves")
    }

    @Test func theCloseButtonHidesTheCardUntilOtherMediaStarts() async throws {
        let h = try await make()
        defer { h.tearDown() }
        h.card.setHovered(true)
        h.card.closeButton.onPress?()
        await h.until { !h.cardIsShown }
        #expect(!h.cardIsShown, "the x left the card up")

        // The same track paused and played again is the same media: the card stays away.
        h.source.nowPlaying = Self.track(playing: false)
        h.source.nowPlaying = Self.track(playing: true)
        await h.until({ h.cardIsShown }, within: .milliseconds(400))
        #expect(!h.cardIsShown, "the hidden track brought its card back by pausing and playing")

        // Other media starting brings the card back.
        h.source.nowPlaying = Self.track("Clair de Lune")
        await h.until { h.cardIsShown }
        #expect(h.cardIsShown, "a new track did not bring the card back")
        #expect(h.card.titleLabel.stringValue == "Clair de Lune")
    }

    @Test func rightClickingTheCardOffersItsHideRowsAndPlayPause() async throws {
        let h = try await make()
        defer { h.tearDown() }
        let titles = Self.titles(h.rightClickCard())
        for title in ["Hide", "Hide Until Relaunch", "Never Show Media Card", "Play/Pause"] {
            #expect(titles.contains(title), "the card's menu \(titles) has no \(title)")
        }
        // Every row runs a bound action: the menu is generated from the actions, not a hand list.
        for id in ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .nowPlayingCard)) {
            #expect(h.services.registry.isBound(id), "\(id) is in the card's menu but runs nothing")
        }
    }

    @Test func playPauseFromTheMenuReachesTheSource() async throws {
        let h = try await make()
        defer { h.tearDown() }
        let menu = try #require(h.rightClickCard())
        let item = try #require(menu.items.first { $0.title == "Play/Pause" })
        menu.performActionForItem(at: menu.index(of: item))
        await h.until { h.source.commands == [.playPause] }
        #expect(h.source.commands == [.playPause], "Play/Pause sent \(h.source.commands)")
    }

    @Test func hideUntilRelaunchKeepsTheCardAwayFromNewMediaAndShowBringsItBack() async throws {
        let h = try await make()
        defer { h.tearDown() }
        _ = h.services.registry.perform("nowPlaying.hideCardUntilRelaunch")
        await h.until { !h.cardIsShown }
        #expect(!h.cardIsShown)
        h.source.nowPlaying = Self.track("Clair de Lune")
        await h.until({ h.cardIsShown }, within: .milliseconds(400))
        #expect(!h.cardIsShown, "new media brought back a card hidden until relaunch")
        _ = h.services.registry.perform("nowPlaying.showCard")
        await h.until { h.cardIsShown }
        #expect(h.cardIsShown, "Show Media Card did not bring it back")
    }

    @Test func neverShowTurnsTheSettingOffAndShowTurnsItBackOn() async throws {
        let h = try await make()
        defer { h.tearDown() }
        _ = h.services.registry.perform("nowPlaying.disableCard")
        await h.until { !h.cardIsShown && h.savedEnabled() == false }
        #expect(h.savedEnabled() == false, "Never Show Media Card left sidebar.nowPlaying.enabled on")
        #expect(!h.cardIsShown)
        _ = h.services.registry.perform("nowPlaying.showCard")
        await h.until { h.cardIsShown && h.savedEnabled() == true }
        #expect(h.savedEnabled() == true, "Show Media Card did not turn sidebar.nowPlaying.enabled on")
        #expect(h.cardIsShown)
    }

    /// The card's actions reach every surface: the palette, the CLI and MCP (one action each).
    @Test(arguments: ["nowPlaying.hideCard", "nowPlaying.hideCardUntilRelaunch", "nowPlaying.disableCard", "nowPlaying.showCard",
                      "nowPlaying.playPause", "tab.pictureInPicture"])
    func everyCardActionIsInThePaletteTheCLIAndMCP(_ id: String) throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == ActionID(rawValue: id) }, "\(id) is not an action")
        #expect(descriptor.surfacePlan.palette.isOffered, "\(id) is not in the palette")
        #expect(descriptor.surfacePlan.cli?.isOffered == true, "\(id) has no CLI verb")
        #expect(descriptor.surfacePlan.mcp?.isOffered == true, "\(id) is not an MCP tool")
    }
}
