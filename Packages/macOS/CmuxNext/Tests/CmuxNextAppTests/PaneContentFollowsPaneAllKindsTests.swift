import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextPages
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-11: "for perf, when i resize panes, for like file viewer, it doesnt have smooth animation, check
/// all pane types, all must have smooth transition". The contract of every kind of pane content (`TabContent.Kind`):
/// while a keyboard resize moves its pane, its view has its content area's rect in EVERY frame, and the landing's
/// frame is the rest size, with no other size after it.
///
/// Before: the area kept every view that was not a terminal's host, a browser's chrome or Home at the size it had
/// when the press began and gave it the pane's size once, after the landing (FRAME OWNER S1), so a file viewer, an
/// agent chat, a placeholder and a notice stood still while their pane moved, then jumped.
///
/// The kinds come from `TabContent.Kind.allCases` and each fixture is made in a switch with no default, so a new kind
/// does not compile here until it has a fixture, and then has this contract or fails.
///
/// No kind and no page is an exception. The docked Home and the Home page tab follow their pane too (the Home tests,
/// the last ones here). They were the one stated exception until 2026-11-13 (cmux#41105: held at the size they had
/// when the key was pressed, because a Home that followed missed each second refresh after a key press); the commit
/// that ended it moved their tests from "held" to "follows" here.
///
/// The app's own pane content (`PaneContentView`) shows the kind in p2 of p1 | p2; one press on p2 (`PaneResize.press`)
/// moves the divider. The test is the spring's clock, one frame per step.
///
/// Not covered here: the pixels a producer on another thread or process draws in that rect (a terminal's surface:
/// `TerminalKeyResizeFrameTests`; a Chromium page: `CEFPageFrameOwnerTests`; the Chromium fixture here is the mock
/// engine's page in the real chrome).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneContentFollowsPaneAllKindsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// One kind's content as the app shows it, what keeps it alive, and how it goes.
    struct Shown {
        let content: TabContent
        var keeping: [Any] = []
        var close: @MainActor () -> Void = {}
    }

    /// The content of `kind`, made as the app makes it.
    static func shown(_ kind: TabContent.Kind) throws -> Shown {
        _ = NSApplication.shared
        switch kind {
        case .terminal:
            let services = AppServices(environment: AppEnvironment.current([:]))
            let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), title: "~"))
            let scripted = ScriptedTerminalIO()
            let session = TerminalSession(io: scripted)
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            let attachment = TerminalAttachment.Target(surface: tab.surface, terminalResourceID: nil, generation: nil)
            let io = DaemonTerminalIO(target: .init(attachment: attachment, initialSize: CellSize(cols: 80, rows: 24)), resizes: ResizeCoordinator(),
                                      visible: false, endpoint: { throw CancellationError() })
            let entry = TerminalEntry(validity: "test", session: session, io: io, themeKey: TerminalThemeKey(machine: services.daemon.machineID, tab: tab),
                                      store: services.daemon.store, surface: tab.surface)
            return Shown(content: .terminal(entry), keeping: [services, tab], close: { scripted.finish() })
        case .chromium:
            let page = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://a.example/")))
            let entry = BrowserEntry(tab: page), chrome = BrowserPaneChrome()
            chrome.bind(entry.tab, state: entry.state)
            return Shown(content: .browser(entry), keeping: [chrome], close: { chrome.drop() })
        case .webkit:
            let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
            let entry = BrowserEntry(tab: page), chrome = BrowserPaneChrome()
            chrome.bind(entry.tab, state: entry.state)
            return Shown(content: .browser(entry), keeping: [chrome], close: {
                chrome.drop()
                page.close()
            })
        case .agent:
            let directory = FileManager.default.temporaryDirectory.appending(path: "pane-follows-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "index.html")
            try Data("<html><body>Agent</body></html>".utf8).write(to: file)
            let chat = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
            return Shown(content: .agent(chat), close: {
                chat.close()
                try? FileManager.default.removeItem(at: directory)
            })
        case .page:
            // The file viewer's page (Lawrence's example): a React page in an internal page tab.
            let files = try #require(PageWebView(descriptor: .files, routes: []))
            return Shown(content: .page(InternalPageView(key: "pane-follows-files", page: .files, content: files)))
        case .placeholder:
            return Shown(content: .placeholder(RemoteTerminalPlaceholderView(frame: .zero)))
        case .notice:
            return Shown(content: .notice(AgentTabElsewhereView(machine: "studio")))
        case .conversation:
            let (services, _) = HomeLaunchRevealTests.services()
            return Shown(content: .conversation(HomeHostView(services: services, conversation: "conv_local")), keeping: [services])
        }
    }

    /// p1 | p2 in a 1200 x 800 window: p2 shows `content`, p1 a plain view.
    final class Panes: LayoutPaneContentProvider {
        let reveal: LaunchReveal = {
            let reveal = LaunchReveal()
            reveal.markAllReady()
            return reveal
        }()
        let content: NSView
        var views: [LayoutPaneID: PaneContentView] = [:]

        init(content: NSView) { self.content = content }

        func makeContentView(for pane: LayoutPaneID) -> NSView {
            let tabs = (0..<2).map { TabItem(id: TabID("\(pane.rawValue)-tab\($0)"), title: "Tab \($0)") }
            let view = PaneContentView(stripModel: TabStripModel(tabs: tabs, selectedID: tabs[0].id), reveal: reveal)
            view.show(pane == "p2" ? content : NSView())
            views[pane] = view
            return view
        }
    }

    /// What the landing leaves for after its commit; the test runs it when it says.
    @MainActor final class Landing {
        var work: [@MainActor () -> Void] = []
    }

    /// Every size `view` takes from now on (one per frame change to a new size).
    @MainActor final class Sizes {
        private let view: NSView
        private var last: CGSize
        private(set) var taken: [CGSize] = []

        init(of view: NSView) {
            self.view = view
            last = view.frame.size
            view.postsFrameChangedNotifications = true
            _ = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteSize() }
            }
        }

        private func noteSize() {
            let size = view.frame.size
            guard size != last else { return }
            last = size
            taken.append(size)
        }
    }

    /// `view`'s rect in its window, rounded to a tenth of a point.
    static func rect(_ view: NSView) -> CGRect {
        let rect = view.convert(view.bounds, to: nil)
        func tenth(_ value: CGFloat) -> CGFloat { (value * 10).rounded() / 10 }
        return CGRect(x: tenth(rect.minX), y: tenth(rect.minY), width: tenth(rect.width), height: tenth(rect.height))
    }

    /// One press on p2 (the divider between p1 and p2 moves, so p2's left edge moves and its width changes), run to its
    /// landing and past it. The contract: `content` has its content area's rect in EVERY frame, is at the rest size in
    /// the landing's frame and takes no other size after it; `inner` (what a page tab's view shows) has that rect too; and
    /// the key resize holds the pane's content area, never the whole pane. `also`: what else is wrong in a frame, or nil.
    static func expectFollowsOnePress(_ name: String, content: NSView, inner: NSView?, pane: PaneContentView, model: LayoutModel, root: LayoutRootView,
                                      landing: Landing, also: @MainActor () -> String? = { nil }) throws {
        let area = pane.contentHost
        let start = rect(area)
        try #require(start.width > 100 && start.height > 100, "the pane's content area is \(start) before the press")
        #expect(rect(content) == start, "at rest the \(name) content is at \(rect(content)), its area at \(start)")
        #expect(pane.paneMotionHoldArea === area, "\(name): a key resize holds the whole pane, its tab strip too, not the pane's content area")

        #expect(PaneResize.press("p2", .left, model: model, view: root))
        var off: [String] = []
        var areas: [CGRect] = []
        var frames = 0
        while frames < 240, root.advanceFrame(1.0 / 120) {
            root.layoutSubtreeIfNeeded()
            frames += 1
            let now = rect(area)
            areas.append(now)
            if rect(content) != now { off.append("frame \(frames): content \(rect(content)), area \(now)") }
            if let inner, rect(inner) != now { off.append("frame \(frames): page \(rect(inner)), area \(now)") }
            if let wrong = also() { off.append("frame \(frames): \(wrong)") }
        }
        try #require(frames > 3, "the press did not spring (\(frames) frames)")
        try #require(Set(areas.map(\.width)).count > 3, "the pane's content area did not move with the spring: \(Set(areas.map(\.width)).sorted())")
        #expect(off.isEmpty, "\(name): the content was not at its area's rect in \(off.count) of \(frames) frames: \(off.prefix(3))")

        // The landing's frame, then what the landing leaves for after its commit: the content is at the rest size in the
        // landing's frame and takes no other size after it.
        root.layoutSubtreeIfNeeded()
        let landed = rect(area)
        #expect(rect(content) == landed, "\(name): at the landing's frame the content is at \(rect(content)), its area at \(landed)")
        let later = Sizes(of: content)
        let release = landing.work
        landing.work.removeAll()
        for work in release { work() }
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        #expect(!area.isHolding, "the hold did not end at the landing")
        #expect(landed.width != start.width, "the press did not change the pane's width: \(landed), was \(start)")
        #expect(rect(area) == landed, "the content area changed after the landing's frame: \(rect(area)), was \(landed)")
        #expect(rect(content) == landed, "\(name): after the landing the content is at \(rect(content)), its area at \(landed)")
        if let inner { #expect(rect(inner) == landed, "\(name): after the landing the page is at \(rect(inner)), its area at \(landed)") }
        #expect(later.taken.isEmpty, "\(name): the content took \(later.taken.count) more size(s) after the landing's frame: \(later.taken)")
        if let wrong = also() { Issue.record("\(name): after the landing: \(wrong)") }
    }

    @Test(arguments: TabContent.Kind.allCases)
    func theContentHasItsAreasRectInEveryFrameOfAKeyResize(_ kind: TabContent.Kind) throws {
        let shown = try Self.shown(kind)
        defer { withExtendedLifetime(shown.keeping) { shown.close() } }
        #expect(shown.content.kind == kind, "the fixture of \(kind) made a \(shown.content.kind)")
        let content = shown.content.view

        let provider = Panes(content: content)
        let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.closeAfterTest() }
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        let landing = Landing()
        root.context.afterCommit = { [landing] in landing.work.append($0) }

        let pane = try #require(provider.views["p2"])
        try #require(content.window === window, "the pane does not show the \(kind) content")
        // The page inside an internal page tab (the file viewer's web view) is what the person sees: it fills its tab's view.
        let inner: NSView? = if case .page(let page) = shown.content { page.content } else { nil }
        try Self.expectFollowsOnePress("\(kind)", content: content, inner: inner, pane: pane, model: model, root: root, landing: landing)
    }

    /// THE 2 HOME PAGES, WHICH FOLLOW THEIR PANE AS EVERY KIND DOES. They are pages (`TabContent.Kind.page`, as the file
    /// viewer's above) with a native view, and they were the one stated exception (cmux#41105): held at the size they
    /// had when the key was pressed, with one new size after the landing, a jump the person saw after the pane came to
    /// rest. What the follow costs in a frame is not a matter for this test (a count of frames, no time): the films of
    /// the commit that ended the exception measure it.
    ///
    /// A conversation tab (`TabContent.Kind.conversation`, the same Home view straight in the pane) is in the kinds above.
    nonisolated enum Home: CaseIterable, Sendable {
        /// The docked Home (`InternalPageID.homeDock`, a `HomeDockView`).
        case docked
        /// The Home as a pane tab (`InternalPageID.homeTab`, a `TopHomePageView`).
        case pageTab
    }

    /// The Home page of `home`, made as its tab provider makes it (`HomeDockTab`, `HomePageTab`).
    static func page(_ home: Home, services: AppServices) -> InternalPageView {
        switch home {
        case .docked:
            // No tools for the tab row, whatever tools maker the process has (`HomeDockSwitchView.makeRowTools`, set by
            // `AppActions.bind` in other suites of this process): a fixture that wants tools sets them itself.
            let dock = HomeDockView(services: services, mode: .messages)
            dock.rowTools = [:]
            return InternalPageView(key: "pane-follows-home-dock", page: .homeDock, content: dock)
        case .pageTab:
            return InternalPageView(key: "pane-follows-home-tab", page: .homeTab, content: TopHomePageView(services: services, windowKey: { "pane-follows-home-tab" }))
        }
    }

    /// The Home, and the Home's own view in its page, have the content area's rect in every frame of the press, and the
    /// rest size in the landing's frame with no other size after it: no size kept from before the press, no jump after
    /// the pane came to rest.
    @Test(arguments: Home.allCases)
    func theHomeHasItsAreasRectInEveryFrameOfAKeyResize(_ home: Home) throws {
        let (services, _) = HomeLaunchRevealTests.services()
        let page = Self.page(home, services: services)
        defer { withExtendedLifetime(services) { (page.content as? HomeDockView)?.close() } }

        let provider = Panes(content: page)
        let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.closeAfterTest() }
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        let landing = Landing()
        root.context.afterCommit = { [landing] in landing.work.append($0) }

        let pane = try #require(provider.views["p2"])
        try #require(page.window === window, "the pane does not show the \(home) Home")
        try Self.expectFollowsOnePress("the \(home) Home", content: page, inner: page.content, pane: pane, model: model, root: root, landing: landing)
    }

    /// The docked Home's tools for its pane's tab row (the app gives it the Chief's, `HomeDockSwitchView.makeRowTools`).
    final class RowTools: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: 60, height: 20) }
    }

    /// p1 | p2 in a 1200 x 800 window, at rest: p2 shows the docked Home with its tools in the pane's tab row.
    static func dockedHomeWithRowTools() throws -> (services: AppServices, page: InternalPageView, tools: RowTools, provider: Panes,
                                                    model: LayoutModel, root: LayoutRootView, window: NSWindow, landing: Landing) {
        let (services, _) = HomeLaunchRevealTests.services()
        let page = Self.page(.docked, services: services), tools = RowTools()
        let dock = try #require(page.content as? HomeDockView, "the docked Home's page does not show a HomeDockView")
        dock.rowTools = [.messages: tools]
        let provider = Panes(content: page)
        let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        // The Home reports its tools' width in its first layout; its pane gives them the row in its next one.
        for _ in 0..<3 {
            provider.views["p2"]?.needsLayout = true
            root.layoutSubtreeIfNeeded()
        }
        root.driver.isManual = true
        let landing = Landing()
        root.context.afterCommit = { [landing] in landing.work.append($0) }
        return (services, page, tools, provider, model, root, window, landing)
    }

    /// The docked Home as the app shows it, with its tools in its pane's tab row (the Chief's): it follows its pane with
    /// its tools, as a chat in the tab row does (`PaneTabRowPerPageHoldTests`). In every frame of the press the content
    /// area is the pane's whole rect, the Home has that rect, and its tools are in the row. Before: the pane's host held
    /// the WHOLE pane, its tab strip too, at the size it had when the key was pressed (`PaneContentAreaView.holdArea`
    /// gave no area), and the pane took its rest size once, after the landing.
    @Test func theDockedHomeWithItsToolsInTheTabRowFollowsItsPaneThroughAKeyResize() throws {
        let rig = try Self.dockedHomeWithRowTools()
        defer { rig.window.closeAfterTest() }
        defer { withExtendedLifetime(rig.services) { (rig.page.content as? HomeDockView)?.close() } }
        let (page, tools) = (rig.page, rig.tools)
        let pane = try #require(rig.provider.views["p2"]), area = pane.contentHost
        try #require(page.window === rig.window && !tools.isHidden, "fixture: the pane does not show the docked Home with its tools in the tab row")
        try #require(Self.rect(area) == Self.rect(pane), "fixture: with the Home's tools in the tab row the content area \(Self.rect(area)) is not the pane's whole rect \(Self.rect(pane))")
        try Self.expectFollowsOnePress("the docked Home with its tools in the tab row", content: page, inner: page.content, pane: pane, model: rig.model,
                                       root: rig.root, landing: rig.landing) {
            if tools.isHidden { return "the Home's tools are not in the tab row" }
            return Self.rect(area) == Self.rect(pane) ? nil : "the content area \(Self.rect(area)) is not the pane's whole rect \(Self.rect(pane))"
        }
    }

    /// The tab that its pane shows when the key is pressed, before the tab change to the docked Home.
    nonisolated enum TabBefore: CaseIterable, Sendable {
        /// A plain tab (a terminal): the content area is under the pane's tab strip, and the parked Home's frame is not
        /// the area's.
        case underTheStrip
        /// A chat with its tools in the tab row: the content area is the whole pane, as the parked Home's frame is, so
        /// the Home comes in filling the area (review of cmux#41291).
        case inTheTabRow
    }

    /// A tab change to the docked Home INSIDE a key hold of its pane (the press was on another tab; the Home was parked
    /// at the frame it shows at, with its tools in the tab row). The rule of a chat shown during a key resize
    /// (`PaneTabRowPerPageHoldTests`, (b)) is the Home's too: from the tab change on, the Home has its content area's
    /// rect in every frame; its tools are in the row only while the area is the pane's whole rect, and without them the
    /// area is under the pane's tab strip; after the landing its tools are in the row and it has its pane's rect.
    ///
    /// History (reviews of cmux#41105 and cmux#41291, while the Home was held): its first layout in the hold took the row
    /// at the pane's whole size, the next frame held it at that size while the area went back under the strip, and a band
    /// with the Home's tools showed under the strip until the landing. A Home at a rect that is not its area's is that
    /// band, so this rule pins it.
    @Test(arguments: TabBefore.allCases)
    func theDockedHomeShownInsideAKeyHoldHasItsAreasRectInEveryFrame(_ before: TabBefore) throws {
        let rig = try Self.dockedHomeWithRowTools()
        defer { rig.window.closeAfterTest() }
        defer { withExtendedLifetime(rig.services) { (rig.page.content as? HomeDockView)?.close() } }
        let (page, root, landing) = (rig.page, rig.root, rig.landing)
        let pane = try #require(rig.provider.views["p2"]), area = pane.contentHost
        try #require(page.window === rig.window && !rig.tools.isHidden && Self.rect(area) == Self.rect(pane),
                     "fixture: the pane does not show the docked Home with its tools in the tab row")

        // Another tab of the pane shows: the Home is parked, and the area is under the pane's tab strip.
        pane.show(NSView())
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        try #require(page.isHidden && page.superview === area, "fixture: the Home is not parked in its pane")
        let under = Self.rect(area)
        try #require(under.height < Self.rect(pane).height - 8, "fixture: with a plain tab shown the content area \(under) is not under the tab strip of \(Self.rect(pane))")
        if before == .inTheTabRow {
            // A chat with its tools in the tab row shows in place of the plain tab: the content area is the whole pane.
            let chat = PaneTabRowPerPageHoldTests.RowPage()
            pane.show(chat)
            chat.report(60)
            for _ in 0..<3 {
                pane.needsLayout = true
                root.layoutSubtreeIfNeeded()
            }
            try #require(chat.drawnRow > 0 && Self.rect(area) == Self.rect(pane) && page.isHidden && page.superview === area,
                         "fixture: the chat is not in the tab row with the Home parked: row \(chat.drawnRow), area \(Self.rect(area)), pane \(Self.rect(pane))")
        }

        // One press on that tab, three frames of its spring, then the tab change to the Home.
        #expect(PaneResize.press("p2", .left, model: rig.model, view: root))
        var frames = 0
        while frames < 3, root.advanceFrame(1.0 / 120) {
            root.layoutSubtreeIfNeeded()
            frames += 1
        }
        try #require(frames == 3 && area.isHolding, "fixture: the press holds no content area after \(frames) frames")
        pane.show(page)
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        try #require(!page.isHidden, "fixture: the tab change did not show the Home")
        var off: [String] = []
        var widths: Set<CGFloat> = []
        func look(_ when: String) {
            let (now, nowArea, nowPane) = (Self.rect(page), Self.rect(area), Self.rect(pane))
            widths.insert(now.width)
            let inRow = !rig.tools.isHidden
            if now != nowArea || (inRow ? nowArea != nowPane : nowArea.height != under.height) {
                off.append("\(when): the Home \(now), its area \(nowArea), its pane's content \(nowPane) (under the strip: \(under.height) pt high), its tools in the row: \(inRow)")
            }
        }
        look("the tab change")
        while frames < 240, root.advanceFrame(1.0 / 120) {
            root.layoutSubtreeIfNeeded()
            frames += 1
            look("frame \(frames)")
        }
        try #require(frames > 6, "the press did not spring after the tab change (\(frames) frames)")
        #expect(widths.count > 3, "\(before): the Home shown inside the key hold did not move with its pane: widths \(widths.sorted())")
        #expect(off.isEmpty, "\(before): the Home shown inside the key hold was not at its area's rect, or had its tools' row off the strip's row, \(off.count) times: \(off.prefix(3))")

        // After the landing the Home has the row and its pane's rect.
        root.layoutSubtreeIfNeeded()
        let release = landing.work
        landing.work.removeAll()
        for work in release { work() }
        for _ in 0..<3 { root.layoutSubtreeIfNeeded() }
        #expect(!area.isHolding, "the hold did not end at the landing")
        #expect(!rig.tools.isHidden, "after the landing the Home's tools are not in the tab row")
        #expect(Self.rect(page) == Self.rect(pane), "after the landing the Home is at \(Self.rect(page)), its pane's content at \(Self.rect(pane))")
    }
}
