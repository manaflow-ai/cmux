import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// The rule of an agent chat in a pane spring (#36677, Leo 2026-11-05: "the main pane waits for the right pane to shift
/// before it shifts. Like, why are you waiting?"): in a split beside it, the close of the pane beside it, a zoom and the
/// unzoom, the chat takes its REST size in the spring's first frame and keeps it to the landing, so that its page
/// lays out once per spring. A page that gets a size per frame lays out per frame, and one layout of a long chat takes
/// longer than the spring: on a film of #41411, which gave the chat its pane's size in every frame, the final wrap of a
/// 150-row chat came 90 to 190 ms later in each of these four motions.
///
/// What the test measures: the SIZES of the pane's view (what the layout sizes) and of the chat's view in it, read in
/// each frame of the spring and from their frame notices. It does not count page layouts and it does not measure the
/// film's times: a page lays out when its view takes a new size, and that is the part the layout decides.
///
/// The app's own answer decides here: a real `WorkspaceContentController` on an offline store, whose
/// `holdsContentInMotion(for:)` reads the content its pane shows. The other tests of the held size
/// (`PaneMotionContentHoldTests`, `PaneHeldContentLandingTests`, `HeldChatKeepsItsRightEdgeTests` and others) give the
/// layout a provider that holds by the test's own word, so none of them fails when the workspace stops holding a chat.
///
/// Each change runs as its key's turn runs it (Split Right: `DaemonStore.intend(.splitPane)`; Close:
/// `PaneController.prepareClose`; Toggle Pane Zoom: `DaemonStore.intend(.zoomPane)`). The test is the layout's clock
/// (`DisplayLinkDriver.isManual`, 120 Hz steps) and runs no main-actor turn in a motion.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct AgentChatTakesOneSizePerSpringTests {
    static let dt = 1.0 / 120

    /// What changes the chat's pane.
    enum Change: String, CaseIterable, CustomTestStringConvertible {
        case splitBesideIt, closeOfThePaneBesideIt, zoomAndUnzoom
        var testDescription: String { rawValue }
    }

    static let chatPane = CmuxNextDaemon.PaneID(rawValue: 1), besidePane = CmuxNextDaemon.PaneID(rawValue: 2)

    /// One column over the whole screen: the pane alone, or the pane and one beside it. No tab is of a kind the app draws.
    private static func tree(paneBeside: Bool) -> DaemonTree {
        let ids = paneBeside ? [chatPane, besidePane] : [chatPane]
        let panes = ids.map { PaneSnapshot(id: $0, tabs: [TabSnapshot(surface: CmuxNextDaemon.SurfaceID(rawValue: $0.rawValue), kind: .other("chat-one-size-test"), title: "chat")]) }
        let layout: LayoutNode = paneBeside ? .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(chatPane), b: .leaf(besidePane)) : .leaf(chatPane)
        let column = ColumnSnapshot(id: CmuxNextDaemon.ColumnID(rawValue: 11), width: 1, layout: layout)
        let screen = ScreenSnapshot(id: 1, layout: layout, columns: [column], panes: panes)
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"agent-chat-one-size-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    @Test(.timeLimit(.minutes(1)), arguments: Change.allCases)
    func theChatTakesItsRestSizeOnceInTheSpring(of change: Change) throws {
        typealias Kinds = PaneContentFollowsPaneAllKindsTests
        let shown = try Kinds.shown(.agent)
        defer { withExtendedLifetime(shown.keeping) { shown.close() } }
        guard case .agent(let chat) = shown.content else {
            Issue.record("fixture: the agent kind's content is \(shown.content.kind)")
            return
        }
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
        // The pane springs are on for this layout, whatever the shared settings say: the override decides
        // `canAnimate` and `animatesPaneLayout`, and the frame step reads the shared policy for the spring's numbers only.
        root.context.reduceMotionOverride = false
        let landing = Kinds.Landing()
        root.context.afterCommit = { [landing] in landing.work.append($0) }
        root.driver.isManual = true
        root.driver.detach()
        root.driver.attach(to: root)
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        var settling = 0
        while settling < 600, root.advanceFrame(Self.dt) { settling += 1 }
        try #require(settling < 600, "fixture: the layout did not come to rest in 600 frames")

        // The pane shows its tab (the app draws nothing for that tab's kind), then the chat, which goes where the
        // pane's controller reads what it shows (`PaneController.currentContent`): the workspace's answer comes from there.
        let pane = try #require(content.panes.values.first { $0.pane.handle == Self.chatPane }, "fixture: the workspace's pane is not mounted")
        pane.syncStripFromStore()
        pane.showSelected()
        let key = try #require(pane.currentTabKey, "fixture: the pane shows no tab")
        try #require(pane.currentContent == nil, "fixture: the app drew content for the test's tab")
        let chats = services.agentTabs, chatKey = chats.tabKey(key, machine: services.daemon.machineID)
        chats.views[chatKey] = chat
        unseed = { chats.views[chatKey] = nil }
        try #require(pane.currentContent?.kind == .agent, "fixture: the pane's controller reads \(String(describing: pane.currentContent?.kind)) for the chat")
        let view = shown.content.view
        _ = pane.view.show(view)
        content.contentView.layoutSubtreeIfNeeded()
        content.contentView.layoutSubtreeIfNeeded()
        for work in landing.work { work() }
        landing.work.removeAll()
        let host = try #require(root.context.hosts[pane.layoutPaneID], "fixture: the pane has no host")
        /// The rect the layout gives the pane's content (its host's clip) in the window, to a tenth of a point.
        func paneRect() -> CGRect {
            let rect = host.convert(host.contentRect, to: nil)
            func tenth(_ value: CGFloat) -> CGFloat { (value * 10).rounded() / 10 }
            return CGRect(x: tenth(rect.minX), y: tenth(rect.minY), width: tenth(rect.width), height: tenth(rect.height))
        }
        try #require(view.window === window, "the pane does not show the chat")
        try #require(Kinds.rect(pane.view) == paneRect(), "at rest the pane's view is at \(Kinds.rect(pane.view)) in a pane at \(paneRect())")

        /// Runs `turn` (a key's turn) and the spring it starts, to the landing's frame and what the landing leaves for
        /// after its commit. From the turn to there, the pane's view (what the layout sizes) and the chat in it each
        /// take ONE new size, in the spring's first frame, and that size is the size at the landing. The sizes are read
        /// in each frame too: on a zoom the layout holds the zooming pane's frame notices until the landing
        /// (`ScreenContentView`, `paneFrameNotices`), so the notices alone show one size there whatever each frame had.
        func takesOneSize(_ name: String, _ turn: () throws -> Void) throws {
            let start = paneRect()
            let paneSizes = Kinds.Sizes(of: pane.view), chatSizes = Kinds.Sizes(of: view)
            try turn()
            var widths: Set<CGFloat> = []
            var frames = 0
            var afterTheFirstFrame: (pane: CGSize, chat: CGSize)?
            var inFrames: (pane: [CGSize], chat: [CGSize]) = ([], [])
            while frames < 600, root.advanceFrame(Self.dt) {
                content.contentView.layoutSubtreeIfNeeded()
                frames += 1
                widths.insert(paneRect().width)
                if afterTheFirstFrame == nil { afterTheFirstFrame = (pane.view.frame.size, view.frame.size) }
                if inFrames.pane.last != pane.view.frame.size { inFrames.pane.append(pane.view.frame.size) }
                if inFrames.chat.last != view.frame.size { inFrames.chat.append(view.frame.size) }
            }
            try #require(frames > 3, "\(name) did not spring (\(frames) frames)")
            try #require(frames < 600, "\(name): the spring did not land in 600 frames")
            try #require(widths.count > 3 && abs(paneRect().width - start.width) > 100,
                         "the pane did not move on the spring of \(name): widths \(widths.sorted()), from \(start.width) to \(paneRect().width)")
            content.contentView.layoutSubtreeIfNeeded()
            let release = landing.work
            landing.work.removeAll()
            for work in release { work() }
            content.contentView.layoutSubtreeIfNeeded()
            content.contentView.layoutSubtreeIfNeeded()
            let landed = paneRect()
            #expect(Kinds.rect(pane.view) == landed, "\(name): after the landing the pane's view is at \(Kinds.rect(pane.view)), its pane at \(landed)")
            let first = try #require(afterTheFirstFrame)
            #expect(first.pane == pane.view.frame.size && first.chat == view.frame.size,
                    "\(name): in the spring's first frame the pane's view was \(first.pane) and the chat \(first.chat); at the landing they are \(pane.view.frame.size) and \(view.frame.size)")
            #expect(paneSizes.taken.count == 1,
                    "\(name): the pane's view took \(paneSizes.taken.count) sizes in \(frames) frames, not one: \(paneSizes.taken.prefix(6))")
            #expect(chatSizes.taken.count == 1,
                    "\(name): the chat took \(chatSizes.taken.count) sizes in \(frames) frames, not one: \(chatSizes.taken.prefix(6))")
            #expect(inFrames.pane.count == 1 && inFrames.chat.count == 1,
                    """
                    \(name): read in each of \(frames) frames, the pane's view had \(inFrames.pane.count) sizes and the chat \
                    \(inFrames.chat.count), not one each: \(inFrames.pane.prefix(6)) and \(inFrames.chat.prefix(6))
                    """)
        }

        switch change {
        case .splitBesideIt:
            // Split Right's key turn (`PaneHandlers` split -> `DaemonStore.intend`, then the layout takes it): the pane halves.
            try takesOneSize("the split") {
                store.intend(.splitPane(pane: Self.chatPane, direction: .right, ratio: 0.5, provisional: ProvisionalPane().opening(in: nil)),
                             transaction: ClientTransactionID.generate())
                content.applyCurrent()
            }
        case .closeOfThePaneBesideIt:
            // Close on the last tab of the pane beside it (`PaneController.prepareClose`): that pane leaves, the chat's takes its space.
            let beside = try #require(content.panes.values.first { $0.pane.handle == Self.besidePane }, "fixture: the pane beside it is not mounted")
            beside.syncStripFromStore()
            try takesOneSize("the close") {
                _ = try #require(beside.prepareClose(beside.stripModel.orderedTabs.map(\.id)), "fixture: the close has no daemon tab")
            }
        case .zoomAndUnzoom:
            // Toggle Pane Zoom's key turn (`DaemonService` zoom effect -> `DaemonStore.intend`), then the same key again.
            try takesOneSize("the zoom") {
                store.intend(.zoomPane(pane: Self.chatPane, zoomed: true), transaction: ClientTransactionID.generate())
                content.applyCurrent()
            }
            try takesOneSize("the unzoom") {
                store.intend(.zoomPane(pane: Self.chatPane, zoomed: false), transaction: ClientTransactionID.generate())
                content.applyCurrent()
            }
        }
    }
}
