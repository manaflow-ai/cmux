import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The right sidebar's section icons are made off the main thread before the panel is first shown: opening it
/// (Focus Right Sidebar) made each SF Symbol image in the action's turn, CoreUI's vector decode included (47 ms
/// main-thread stall, light session, macOS 27 sweep). The services build the sections on first use and post
/// the icon build after startup completes (p08-startup-022), so no launch frame waits on CoreUI.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct RightSidebarIconsTests {
    private nonisolated final class Made: Sendable {
        private let onMain = Mutex<[Bool]>([])
        func note() { onMain.withLock { $0.append(Thread.isMainThread) } }
        var threads: [Bool] { onMain.withLock { $0 } }
    }

    @Test func iconsAreMadeOffTheMainThreadAfterStartupOnceAndThePanelUsesThem() async {
        let made = Made()
        let (calls, call) = AsyncStream.makeStream(of: Void.self)
        let sections = RightSidebarSections(symbolImage: { name in
            made.note()
            call.yield()
            return NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in name.isEmpty }
        })
        sections.register(.files) { _ in NSView() }
        sections.register(.feed) { _ in NSView() }
        let s = StartupTestScheduler()
        sections.postIconBuild(on: s.startup)
        s.hand.drain()
        #expect(s.startup.log.records.map(\.name.description) == ["RightSidebar.icons"])
        #expect(s.startup.log.records.map(\.destination) == [.lane(.cpu, .idle)])
        #expect(made.threads.isEmpty, "the icons wait for startup complete")

        s.complete()
        var imageCalls = calls.makeAsyncIterator()
        _ = await imageCalls.next()
        _ = await imageCalls.next()
        // The lane posts the landing to main when its two images are made; run hops and frames until it lands.
        while !sections.iconsReady {
            await Task.yield()
            s.hand.drain()
            s.fire()
        }
        #expect(made.threads == [false, false], "icons made: \(made.threads) (true = on the main thread)")
        #expect(s.startup.log.records.map(\.name.description) == ["RightSidebar.icons", "RightSidebar.icons.land"])

        let view = RightSidebarView(modes: sections.modes, title: { $0.rawValue }, icon: sections.icon,
                                    makeSection: { _ in nil }, run: { _ in })
        #expect(view.barButtons[.files]?.image === sections.icon(.files))
        #expect(made.threads.count == 2, "the panel made its own icons")
    }

    @Test func aPanelShownBeforeStartupCompletesMakesItsIconsAndTheLateBuildKeepsThem() async {
        let sections = RightSidebarSections(symbolImage: { name in
            NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in name.isEmpty }
        })
        sections.register(.files) { _ in NSView() }
        let s = StartupTestScheduler()
        sections.postIconBuild(on: s.startup)
        s.hand.drain()
        let early = sections.icon(.files)
        #expect(early != nil, "the panel makes its icon in its own turn before the build")
        s.complete()
        while !sections.iconsReady {
            await Task.yield()
            s.hand.drain()
            s.fire()
        }
        #expect(sections.icon(.files) === early, "the late build never replaces an icon the panel already shows")
    }
}
