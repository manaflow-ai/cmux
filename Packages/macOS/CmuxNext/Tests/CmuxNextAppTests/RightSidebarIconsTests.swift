import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import Testing

/// The right sidebar's section icons are made off the main thread before the panel is first shown: opening it
/// (Focus Right Sidebar) made each SF Symbol image in the action's turn, CoreUI's vector decode included (47 ms
/// main-thread stall, light session, macOS 27 sweep).
@MainActor @Suite(.timeLimit(.minutes(1)))
struct RightSidebarIconsTests {
    private nonisolated final class Made: Sendable {
        private let onMain = Mutex<[Bool]>([])
        func note() { onMain.withLock { $0.append(Thread.isMainThread) } }
        var threads: [Bool] { onMain.withLock { $0 } }
    }

    @Test func iconsAreMadeOffTheMainThreadOnceAndThePanelUsesThem() async {
        let made = Made()
        let sections = RightSidebarSections(symbolImage: { name in
            made.note()
            return NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in name.isEmpty }
        })
        sections.register(.files) { _ in NSView() }
        sections.register(.feed) { _ in NSView() }
        sections.prewarmIcons()
        for await ready in ObservationStream({ sections.iconsReady }) where ready { break }
        #expect(made.threads == [false, false], "icons made: \(made.threads) (true = on the main thread)")

        let view = RightSidebarView(modes: sections.modes, title: { $0.rawValue }, icon: sections.icon,
                                    makeSection: { _ in nil }, run: { _ in })
        #expect(view.barButtons[.files]?.image === sections.icon(.files))
        #expect(made.threads.count == 2, "the panel made its own icons")
    }
}
