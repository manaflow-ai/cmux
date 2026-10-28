import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The right sidebar's section icons are made off the main thread: opening it (Focus Right Sidebar) made each
/// SF Symbol image in the action's turn, CoreUI's vector decode included (47 ms main-thread stall, light
/// session, macOS 27 sweep). The services build the sections on first use; the icon build is
/// a cpu-lane post of the launch's scheduler, after startup from the launch's prewarm, right after the first
/// frame when a panel is built first. A panel shows empty buttons until the images land, so no main turn,
/// the launch window's build included, decodes a symbol.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct RightSidebarIconsTests {
    private nonisolated final class Made: Sendable {
        private let onMain = Mutex<[Bool]>([])
        func note() { onMain.withLock { $0.append(Thread.isMainThread) } }
        var threads: [Bool] { onMain.withLock { $0 } }
    }

    /// Sections with Files and Feed whose symbol images are counted, and the stream of those calls.
    private static func sections(_ startup: StartupScheduler?, _ made: Made) -> (RightSidebarSections, AsyncStream<Void>) {
        let (calls, call) = AsyncStream.makeStream(of: Void.self)
        let sections = RightSidebarSections(startup: startup, symbolImage: { name in
            made.note()
            call.yield()
            return NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in name.isEmpty }
        })
        sections.register(.files) { _ in NSView() }
        sections.register(.feed) { _ in NSView() }
        return (sections, calls)
    }

    /// Runs hops and frames until the lane's images landed on main.
    private static func land(_ sections: RightSidebarSections, _ calls: AsyncStream<Void>, _ s: StartupTestScheduler) async {
        var imageCalls = calls.makeAsyncIterator()
        _ = await imageCalls.next()
        _ = await imageCalls.next()
        while !sections.iconsReady {
            await Task.yield()
            s.hand.drain()
            s.fire()
        }
    }

    @Test func iconsAreMadeOffTheMainThreadAfterStartupOnceAndThePanelUsesThem() async {
        let made = Made()
        let s = StartupTestScheduler()
        let (sections, calls) = Self.sections(s.startup, made)
        sections.buildIcons(.afterStartup)
        s.hand.drain()
        #expect(s.startup.log.records.map(\.name.description) == ["RightSidebar.icons"])
        #expect(s.startup.log.records.map(\.destination) == [.lane(.cpu, .idle)])
        #expect(made.threads.isEmpty, "the icons wait for startup complete")

        s.complete()
        await Self.land(sections, calls, s)
        #expect(made.threads == [false, false], "icons made: \(made.threads) (true = on the main thread)")
        // The landing post comes after completion closed the log, so only the build is recorded.
        #expect(s.startup.log.records.map(\.name.description) == ["RightSidebar.icons"])

        let view = RightSidebarView(modes: sections.modes, title: { $0.rawValue }, icon: sections.icon,
                                    makeSection: { _ in nil }, run: { _ in })
        #expect(view.barButtons[.files]?.image != nil && view.barButtons[.files]?.image === sections.icon(.files))
        sections.buildIcons(.afterFirstFrame)
        #expect(made.threads.count == 2, "the panel and a second build made no icon of their own")
    }

    @Test func aPanelBuiltDuringTheLaunchShowsEmptyButtonsAndFillsThemAfterTheFirstFrame() async {
        let made = Made()
        let s = StartupTestScheduler()
        let (sections, calls) = Self.sections(s.startup, made)
        // What `WindowController.rightSidebarPanel()` does when the window restores with the sidebar shown.
        let view = RightSidebarView(modes: sections.modes, title: { $0.rawValue }, icon: sections.icon,
                                    makeSection: { _ in nil }, run: { _ in })
        sections.whenIconsReady { [weak view] in view?.setIcons($0) }
        sections.buildIcons(.afterFirstFrame)
        s.hand.drain()
        #expect(made.threads.isEmpty, "the panel's build made no symbol image in its turn")
        #expect(view.barButtons.values.allSatisfy { $0.image?.size == .zero }, "empty buttons until the icons land")
        #expect(s.startup.log.records.map(\.priority) == [.afterFirstFrame])

        s.startup.firstFrameCommitted()
        await Self.land(sections, calls, s)
        #expect(s.startup.completion == nil, "the icons land before startup completes")
        #expect(made.threads == [false, false], "icons made: \(made.threads) (true = on the main thread)")
        #expect(s.startup.log.records.map(\.name.description) == ["RightSidebar.icons", "RightSidebar.icons.land"])
        for mode in sections.modes {
            #expect(view.barButtons[mode]?.image != nil && view.barButtons[mode]?.image === sections.icon(mode), "\(mode)")
        }

        sections.buildIcons(.afterStartup)  // the launch's prewarm, later
        s.hand.drain()
        #expect(s.startup.log.records.count == 2, "the build is posted once")
    }

    @Test func aWindowRestoredWithTheSidebarShownMakesNoIconInItsBuild() throws {
        _ = NSApplication.shared
        let s = StartupTestScheduler()
        let services = AppServices(environment: AppEnvironment.current([:]), launchStartup: s.startup)
        let suite = "cmux-right-sidebar-icons-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            for controller in services.windows.controllers { controller.window?.close() }
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(true, forKey: RightSidebarModel.visibleKey)
        services.rightSidebarDefaults = defaults
        services.windows.ordersWindowsIn = false
        AppActions.bind(services)
        let controller = try #require(services.windows.openWindow(workspaces: ["rs-icons-workspace"]))
        let panel = try #require(controller.root.rightPanel)
        s.hand.drain()
        let sections = services.rightSidebarSections
        #expect(!sections.modes.isEmpty)
        #expect(sections.modes.allSatisfy { sections.icon($0) == nil }, "the launch window's build decoded no symbol")
        #expect(panel.barButtons.values.allSatisfy { $0.image?.size == .zero }, "empty buttons until the icons land")
        let builds = s.startup.log.records.filter { $0.name.description == "RightSidebar.icons" }
        #expect(builds.map(\.priority) == [.afterFirstFrame], "the panel posts the build right after the first frame")
        #expect(builds.map(\.destination) == [.lane(.cpu, .idle)])
    }

    @Test func withNoLaunchTheIconsAreMadeAtOnce() {
        let made = Made()
        let (sections, _) = Self.sections(nil, made)
        var landed: [RightSidebarMode: NSImage] = [:]
        sections.whenIconsReady { landed = $0 }
        sections.buildIcons(.afterFirstFrame)
        #expect(sections.iconsReady && Set(landed.keys) == [.files, .feed])
        #expect(made.threads == [true, true], "a host with no launch scheduler makes them in the panel's turn")
    }
}
