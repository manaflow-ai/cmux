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
        private let drawnOnMain = Mutex<[Bool]>([])
        func note() { onMain.withLock { $0.append(Thread.isMainThread) } }
        func drew() { drawnOnMain.withLock { $0.append(Thread.isMainThread) } }
        var threads: [Bool] { onMain.withLock { $0 } }
        var drawThreads: [Bool] { drawnOnMain.withLock { $0 } }
    }

    /// Each icon is made AND first drawn off the main thread (the draw is where a symbol's vectors are
    /// decoded), before the panel takes it.
    @Test func iconsAreMadeAndDrawnOffTheMainThreadOnceAndThePanelUsesThem() async throws {
        let made = Made()
        let sections = RightSidebarSections(symbolImage: { name in
            made.note()
            return NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in
                made.drew()
                return !name.isEmpty
            }
        })
        sections.register(.files) { _ in NSView() }
        sections.register(.feed) { _ in NSView() }
        let prewarm = try #require(sections.prewarmIcons())
        await prewarm.value
        #expect(made.threads == [false, false], "icons made: \(made.threads) (true = on the main thread)")
        #expect(made.drawThreads.count >= 2 && !made.drawThreads.contains(true),
                "icons drawn: \(made.drawThreads) (true = on the main thread; none: the decode is left to the first show)")

        let view = RightSidebarView(modes: sections.modes, title: { $0.rawValue }, icon: sections.icon,
                                    makeSection: { _ in nil }, run: { _ in })
        #expect(view.barButtons[.files]?.image === sections.icon(.files))
        #expect(made.threads.count == 2, "the panel made its own icons")
    }
}
