import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-11: "check all pane types, all must have smooth transition". The contract of every kind of pane
/// content (`TabContent.Kind`) in a change of its pane's layout (a split beside it, the close of the pane beside it, a
/// zoom and the unzoom): while its pane moves on the change's spring, the pane's view has its pane's rect and the content
/// has its content area's rect in EVERY frame, and the landing's frame is the rest size, with no other size after it.
///
/// Before: the workspace told the layout to hold an agent chat (`WorkspaceContentController`, from the content its pane
/// shows), and the pane's host gave the chat its REST size on the spring's first frame and kept it there to the landing,
/// so the chat did not follow its pane; every other kind did.
///
/// The app's own path decides: a real `WorkspaceContentController` on an offline store, and each change as its key's
/// turn runs it (Split Right: `DaemonStore.intend(.splitPane)`; Close: `PaneController.prepareClose`; Toggle Pane Zoom:
/// `DaemonStore.intend(.zoomPane)`). The pane's tab is of a kind the app draws nothing for, so the test shows the kind's
/// content in the pane's view (`PaneContentView.show`) and puts it where the pane's controller reads what it shows
/// (`PaneController.currentContent`): the stores of terminals, browsers, agent chats, notices and Home. The stores of
/// internal pages and of remote terminal placeholders take no view from outside, so for those two kinds the controller
/// reads no content (the app's rule held neither).
///
/// The kinds come from `TabContent.Kind.allCases`; the fixtures are `PaneContentFollowsPaneAllKindsTests.shown(_:)`.
/// The test is the layout's clock (`DisplayLinkDriver.isManual`, 120 Hz steps) and runs no main-actor turn in a motion.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneContentFollowsLayoutChangeAllKindsTests {
    static let dt = 1.0 / 120

    /// What changes the pane's layout.
    enum Change: String, CaseIterable, CustomTestStringConvertible {
        case splitBesideIt, closeOfThePaneBesideIt, zoomAndUnzoom
        var testDescription: String { rawValue }
    }

    static let shownPane = CmuxNextDaemon.PaneID(rawValue: 1), besidePane = CmuxNextDaemon.PaneID(rawValue: 2)

    /// One column over the whole screen: the pane alone, or the pane and one beside it. No tab is of a kind the app draws.
    private static func tree(paneBeside: Bool) -> DaemonTree {
        let ids = paneBeside ? [shownPane, besidePane] : [shownPane]
        let panes = ids.map { PaneSnapshot(id: $0, tabs: [TabSnapshot(surface: CmuxNextDaemon.SurfaceID(rawValue: $0.rawValue), kind: .other("pane-follows-test"), title: "kind")]) }
        let layout: LayoutNode = paneBeside ? .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(shownPane), b: .leaf(besidePane)) : .leaf(shownPane)
        let column = ColumnSnapshot(id: CmuxNextDaemon.ColumnID(rawValue: 11), width: 1, layout: layout)
        let screen = ScreenSnapshot(id: 1, layout: layout, columns: [column], panes: panes)
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"pane-follows-layout-change-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Puts `content` where `pane`'s controller reads what it shows (`PaneController.existingContent(for:)`) and returns
    /// what takes it out again; nil for a kind whose store takes no view from outside.
    static func seed(_ content: TabContent, as key: String, services: AppServices) -> (@MainActor () -> Void)? {
        let chats = services.agentTabs, chatKey = chats.tabKey(key, machine: services.daemon.machineID)
        switch content {
        case .terminal(let entry):
            services.cache.terminals[key] = entry
            return { services.cache.terminals[key] = nil }
        case .browser(let entry):
            services.cache.browsers[key] = entry
            return { services.cache.browsers[key] = nil }
        case .agent(let chat):
            chats.views[chatKey] = chat
            return { chats.views[chatKey] = nil }
        case .notice(let notice):
            chats.notices[chatKey] = notice
            return { chats.notices[chatKey] = nil }
        case .conversation(let home):
            services.home.tabViews[key] = home
            return { services.home.tabViews[key] = nil }
        case .page, .placeholder:
            return nil
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: TabContent.Kind.allCases, Change.allCases)
    func theContentFollowsItsPaneInEveryFrame(_ kind: TabContent.Kind, of change: Change) throws {
        let shown = try PaneContentFollowsPaneAllKindsTests.shown(kind)
        defer { withExtendedLifetime(shown.keeping) { shown.close() } }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree(paneBeside: change != .splitBesideIt))
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        // The controller holds its window state unowned: the test keeps it alive, as its window does.
        let state = WindowState(record: record)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        var unseed: (@MainActor () -> Void)?
        defer {
            unseed?()
            withExtendedLifetime((services, state)) { content.teardown(); window.close() }
        }
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        let root = content.layoutView
        root.context.reduceMotionOverride = false // the pane springs are on, whatever the shared settings say
        let landing = PaneContentFollowsPaneAllKindsTests.Landing()
        root.context.afterCommit = { [landing] in landing.work.append($0) }
        root.driver.isManual = true
        root.driver.detach()
        root.driver.attach(to: root)
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        var settling = 0
        while settling < 600, root.advanceFrame(Self.dt) { settling += 1 }

        // The pane shows its tab (the app draws nothing for that tab's kind), then the kind's content.
        let pane = try #require(content.panes.values.first { $0.pane.handle == Self.shownPane }, "fixture: the workspace's pane is not mounted")
        pane.syncStripFromStore()
        pane.showSelected()
        let key = try #require(pane.currentTabKey, "fixture: the pane shows no tab")
        try #require(pane.currentContent == nil, "fixture: the app drew content for the test's tab")
        unseed = Self.seed(shown.content, as: key, services: services)
        if unseed != nil {
            #expect(pane.currentContent?.kind == kind, "the pane's controller reads \(String(describing: pane.currentContent?.kind)) for the \(kind) content")
        }
        let view = shown.content.view
        pane.view.show(view)
        content.contentView.layoutSubtreeIfNeeded()
        content.contentView.layoutSubtreeIfNeeded()
        for work in landing.work { work() }
        landing.work.removeAll()
        let host = try #require(root.context.hosts[pane.layoutPaneID], "fixture: the pane has no host")
        let area = pane.view.contentHost
        typealias Rects = PaneContentFollowsPaneAllKindsTests
        /// The rect the layout gives the pane's content (its host's clip) in the window, to a tenth of a point.
        func paneRect() -> CGRect {
            let rect = host.convert(host.contentRect, to: nil)
            func tenth(_ value: CGFloat) -> CGFloat { (value * 10).rounded() / 10 }
            return CGRect(x: tenth(rect.minX), y: tenth(rect.minY), width: tenth(rect.width), height: tenth(rect.height))
        }
        try #require(view.window === window, "the pane does not show the \(kind) content")
        try #require(Rects.rect(pane.view) == paneRect() && Rects.rect(view) == Rects.rect(area),
                     "at rest the pane's view is at \(Rects.rect(pane.view)) in a pane at \(paneRect()), the \(kind) content at \(Rects.rect(view)) in an area at \(Rects.rect(area))")

        /// Runs `turn` (a key's turn) and the spring it starts, to the landing's frame and what the landing leaves for
        /// after its commit: in every frame the pane's view is at its pane's rect and the content at its area's rect, the
        /// landing's frame is the rest size, and no other size comes after it.
        func follows(_ name: String, _ turn: () throws -> Void) throws {
            let start = paneRect()
            try turn()
            var off: [String] = []
            var widths: Set<CGFloat> = []
            var frames = 0
            while frames < 600, root.advanceFrame(Self.dt) {
                content.contentView.layoutSubtreeIfNeeded()
                frames += 1
                let now = paneRect()
                widths.insert(now.width)
                if Rects.rect(pane.view) != now { off.append("frame \(frames): the pane's view at \(Rects.rect(pane.view)), its pane at \(now)") }
                if Rects.rect(view) != Rects.rect(area) { off.append("frame \(frames): the content at \(Rects.rect(view)), its area at \(Rects.rect(area))") }
            }
            try #require(frames > 3, "\(name) did not spring (\(frames) frames)")
            try #require(widths.count > 3 && abs(paneRect().width - start.width) > 100,
                         "the pane did not move on the spring of \(name): widths \(widths.sorted()), from \(start.width) to \(paneRect().width)")
            #expect(off.isEmpty, "\(kind), \(name): the content was not at its pane's rect in \(off.count) of \(frames) frames: \(off.prefix(3))")
            content.contentView.layoutSubtreeIfNeeded()
            let landed = paneRect()
            #expect(Rects.rect(pane.view) == landed, "\(kind), \(name): at the landing's frame the pane's view is at \(Rects.rect(pane.view)), its pane at \(landed)")
            #expect(Rects.rect(view) == Rects.rect(area), "\(kind), \(name): at the landing's frame the content is at \(Rects.rect(view)), its area at \(Rects.rect(area))")
            let later = PaneContentFollowsPaneAllKindsTests.Sizes(of: view)
            let release = landing.work
            landing.work.removeAll()
            for work in release { work() }
            content.contentView.layoutSubtreeIfNeeded()
            content.contentView.layoutSubtreeIfNeeded()
            #expect(paneRect() == landed && Rects.rect(pane.view) == landed, "\(name): the pane changed after the landing's frame: \(paneRect()), was \(landed)")
            #expect(later.taken.isEmpty, "\(kind), \(name): the content took \(later.taken.count) more size(s) after the landing's frame: \(later.taken)")
        }

        switch change {
        case .splitBesideIt:
            // Split Right's key turn (`PaneHandlers` split -> `DaemonStore.intend`, then the layout takes it): the pane halves.
            try follows("the split") {
                store.intend(.splitPane(pane: Self.shownPane, direction: .right, ratio: 0.5, provisional: ProvisionalPane().opening(in: nil)),
                             transaction: ClientTransactionID.generate())
                content.applyCurrent()
            }
        case .closeOfThePaneBesideIt:
            // Close on the last tab of the pane beside it (`PaneController.prepareClose`): that pane leaves, this one takes its space.
            let beside = try #require(content.panes.values.first { $0.pane.handle == Self.besidePane }, "fixture: the pane beside it is not mounted")
            beside.syncStripFromStore()
            try follows("the close") {
                _ = try #require(beside.prepareClose(beside.stripModel.orderedTabs.map(\.id)), "fixture: the close has no daemon tab")
            }
        case .zoomAndUnzoom:
            // Toggle Pane Zoom's key turn (`DaemonService` zoom effect -> `DaemonStore.intend`), then the same key again.
            try follows("the zoom") {
                store.intend(.zoomPane(pane: Self.shownPane, zoomed: true), transaction: ClientTransactionID.generate())
                content.applyCurrent()
            }
            try follows("the unzoom") {
                store.intend(.zoomPane(pane: Self.shownPane, zoomed: false), transaction: ClientTransactionID.generate())
                content.applyCurrent()
            }
        }
    }
}
