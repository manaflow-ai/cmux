import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextControl
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

/// RFD 0022 item 3, the native pop-in guard. Leo, 2026-11-21, after a film of Claude Code desktop's pane drag, whose
/// third drop left three blank frames (250 to 325 ms of unpainted panes): "we need to be able to do our shit at least as
/// good as them on speed and reliability". A drop here is one state transition: in the frame of the drop's own turn and in
/// every display frame after it, each pane that shows paints its content. No pane shows its ground where its content
/// should be, and no pane's frame moves after its motion rests.
///
/// One case per kind of the tab that is dropped (a terminal, a Chromium page, an agent chat, a file viewer) and per kind
/// of drop the app has (onto a pane's edge: a new split; onto its center: a join; a pane swapped by its header; into a
/// new column; into a dock). The app's own pieces run: a `WorkspaceContentController` on an offline store, its
/// `PaneController`s, the content cache that reparents a moved tab's view (never makes it again), the commit motion of
/// the panes. The drop comes as the daemon's tree after it, applied in one turn as the store's observation applies it
/// (`applyCurrent`); a join selects the tab it took, as its strip does at a drop.
///
/// Deterministic: no timer, no screen capture, no wait. The test is the clock of the layout (`DisplayLinkDriver.isManual`)
/// and of the content presentation (``ContentPresentationScheduler/frames``), and reads each frame from the views and
/// layers right after it. The drop's own turn is a frame too: what it commits shows until the next one, so a pane
/// whose content waits for the next frame there is a blank frame.
///
/// What "painted" reads (``PaneDropRig/blanks(_:)``): the pane's host shows (not hidden, some alpha, some area); its
/// selected tab is the tab it shows; that tab's view is installed in the pane's content area, in the window, not
/// hidden, with a layer and some area; a terminal has its surface in its host with a backing layer of some size; a
/// Chromium page says it draws over its view. A pane that leaves (its tab moved away) and still shows in the motion
/// shows its content too, not its ground. Not read here: the pixels a producer in another thread or process draws in
/// that layer (`TerminalKeyResizeFrameTests`, `CEFPageFrameOwnerTests`).
extension PaneCommitMotionTests {
    /// The kind of the tab that is dropped.
    nonisolated enum Dropped: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case terminal, chromiumPage = "Chromium page", agentChat = "agent chat", fileViewer = "file viewer"
        var testDescription: String { rawValue }
    }

    /// How it is dropped. Before each one, the screen has p1 (the dropped tab alone) left of p2 (a terminal).
    nonisolated enum Drop: String, CaseIterable, CustomTestStringConvertible, Sendable {
        /// On p2's bottom edge: p1 closes and a new p3 under p2 shows the tab.
        case edgeSplit = "on a pane's edge"
        /// On p2's center: p1 closes and p2 shows the tab beside its terminal.
        case join = "into a pane's center"
        /// p1 by its header onto p2: they change places.
        case swap = "pane swap by its header"
        /// Into a new column right of p2: p1 closes, p3 shows the tab there.
        case newColumn = "into a new column"
        /// Into a right dock: p1 closes, p3 shows the tab there.
        case dock = "into a dock"
        var testDescription: String { rawValue }
    }

    @Test(arguments: Dropped.allCases, Drop.allCases)
    func everyPaneIsPaintedInEveryFrameOfADrop(_ dropped: Dropped, _ drop: Drop) throws {
        let rig = try PaneDropRig(dropped, drop)
        defer { rig.close() }
        let atRest = rig.blanks("at rest")
        try #require(atRest.isEmpty, "SETUP: a pane is not painted before the drop: \(atRest)")

        rig.drop()
        var blanks = rig.blanks("the drop's turn")
        rig.commit()
        // Each display frame: the presentation's frame work, the layout's frame tick, the frame's layout, then what the
        // frame left for after its commit. At least 3 frames, then until nothing asks for one (2 s at most).
        var frame = 0, moving = true
        while frame < 240, moving || frame < 3 {
            frame += 1
            moving = rig.step()
            blanks += rig.blanks("frame \(frame)")
            rig.commit()
        }
        try #require(!moving, "the drop's frames did not end in 2 s")
        let target = try #require(rig.target, "SETUP: the pane the tab was dropped into is not mounted")
        try #require(target.currentTabKey == rig.movedKey,
                     "the dropped tab does not show in the pane it was dropped into: it shows \(target.currentTabKey ?? "nothing")")
        #expect(blanks.isEmpty, "\(dropped) \(drop): \(blanks.count) unpainted pane frames, the first: \(blanks.prefix(4))")

        // At rest: no pane's frame or layer moves in the frames after it.
        let rest = rig.paneFrames()
        var moved: [String] = []
        for after in 1...6 {
            _ = rig.step()
            rig.commit()
            let now = rig.paneFrames()
            if now != rest { moved.append("frame \(after) after rest: \(now), at rest \(rest)") }
        }
        #expect(moved.isEmpty, "\(dropped) \(drop): a pane moved after its motion rested: \(moved.prefix(2))")
        #expect(rig.blanks("after rest").isEmpty, "\(dropped) \(drop): a pane is not painted after rest: \(rig.blanks("after rest"))")
    }
}

/// One window of the app on an offline store, at rest, ready for one drop.
@MainActor
final class PaneDropRig {
    typealias Dropped = PaneCommitMotionTests.Dropped
    typealias Drop = PaneCommitMotionTests.Drop

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The file viewer's page (a markdown file), made as its provider makes it: a React page in an internal page tab.
    final class FileViewer: InternalPageProvider {
        let page = InternalPageID.markdown
        var title: String { "notes.md" }
        var symbol: String { "doc.richtext" }
        func makeView(for key: String, in window: WindowController?) -> NSView { PageWebView(descriptor: .markdown, routes: []) ?? NSView() }
    }

    /// The presentation's display frames: `fire()` runs the frame work asked for so far.
    final class Frames: ControlFrameSource, @unchecked Sendable { // touched on the main actor only
        nonisolated(unsafe) private var pending: [@MainActor @Sendable () -> Void] = [] // main actor only
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { pending.append(work) }
        @MainActor var hasPending: Bool { !pending.isEmpty }
        @MainActor func fire() {
            let due = pending
            pending = []
            due.forEach { $0() }
        }
    }

    static let dt = PaneCommitMotionTests.dt
    static let movedSurface = CmuxNextDaemon.SurfaceID(rawValue: 1), terminalSurface = CmuxNextDaemon.SurfaceID(rawValue: 2)
    static func pane(_ id: UInt64) -> CmuxNextDaemon.PaneID { CmuxNextDaemon.PaneID(rawValue: id) }

    let dropped: Dropped
    let kind: Drop
    let services: AppServices
    let state: WindowState
    let window: NSWindow
    let content: WorkspaceContentController
    let frames = Frames()
    private var committed: [@MainActor () -> Void] = []
    private let cleanup: [@MainActor () -> Void]
    let movedKey: String
    var root: LayoutRootView { content.layoutView }
    var store: DaemonStore { services.daemon.store }

    init(_ dropped: Dropped, _ kind: Drop) throws {
        _ = NSApplication.shared
        self.dropped = dropped
        self.kind = kind
        let services = AppServices(environment: AppEnvironment.current([:]))
        self.services = services
        // The test steps the presentation's frames, before any pane is queued.
        services.presentation.frames = frames
        services.launchReveal.markAllReady()
        if dropped == .fileViewer { services.pages.register(FileViewer()) }
        let store = services.daemon.store
        let identity = DaemonIdentity(capabilities: [DaemonCapability.dockColumns.rawValue], generation: DaemonGeneration(rawValue: "pane-drop"))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree(kind, after: false, moved: Self.movedTab(dropped)))
        let workspace = try #require(store.workspaces.first)
        let movedKey = try #require(store.tab(surface: Self.movedSurface)?.id, "SETUP: the store has no dropped tab")
        self.movedKey = movedKey
        cleanup = try Self.seed(dropped, key: movedKey, services: services)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"pane-drop","workspace_key":"w1"}"#.utf8))
        // The controller holds its window state unowned: the rig keeps it alive, as its window does.
        let state = WindowState(record: record)
        self.state = state
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        // The panes move at a commit whatever the shared settings say, and the test is the layout's clock.
        root.context.reduceMotionOverride = false
        root.context.commitMotionOverride = true
        root.context.afterCommit = { [weak self] in self?.committed.append($0) }
        root.driver.isManual = true
        root.driver.detach()
        root.driver.attach(to: root)
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        for pane in content.panes.values {
            pane.syncStripFromStore()
            pane.showSelected()
        }
        var settling = 0
        while settling < 240, step() || settling < 3 {
            commit()
            settling += 1
        }
        commit()
        try #require(settling < 240, "SETUP: the layout did not come to rest")
    }

    /// The view of the dropped tab, put where the app finds it: a Chromium page in the content cache, an agent chat in
    /// the chats' views. A terminal is made by the cache on its first show; a file viewer by its provider.
    private static func seed(_ dropped: Dropped, key movedKey: String, services: AppServices) throws -> [@MainActor () -> Void] {
        switch dropped {
        case .terminal, .fileViewer:
            return []
        case .chromiumPage:
            let page = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://drop.example/")))
            _ = services.cache.install(page, for: movedKey)
            return []
        case .agentChat:
            let directory = FileManager.default.temporaryDirectory.appending(path: "pane-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "index.html", directoryHint: .notDirectory)
            try Data("<html><body>Agent</body></html>".utf8).write(to: file)
            let chat = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
            let chats = services.agentTabs, key = chats.tabKey(movedKey, machine: services.daemon.machineID)
            chats.views[key] = chat
            return [{
                chats.views[key] = nil
                chat.close()
                try? FileManager.default.removeItem(at: directory)
            }]
        }
    }

    // MARK: Trees

    static func movedTab(_ dropped: Dropped) -> TabSnapshot {
        switch dropped {
        case .terminal:
            return TabSnapshot(surface: movedSurface, title: "~")
        case .chromiumPage:
            return TabSnapshot(surface: movedSurface, kind: .browser, title: "Drop", url: "https://drop.example/", browserRenderer: "frontend")
        case .agentChat:
            var tab = TabSnapshot(surface: movedSurface, kind: .conversation, title: "Chat")
            tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: AgentSessionRef.host(installID: "pane-drop-test")))
            return tab
        case .fileViewer:
            var tab = TabSnapshot(surface: movedSurface, kind: .conversation, title: "notes.md")
            tab.conversation = ConversationTabRef(page: InternalPageID.markdown.rawValue)
            return tab
        }
    }

    /// The daemon's tree before the drop (p1 with the dropped tab left of p2 with a terminal) or after it.
    static func tree(_ drop: Drop, after: Bool, moved: TabSnapshot) -> DaemonTree {
        let terminal = TabSnapshot(surface: terminalSurface, title: "~")
        func leaf(_ id: UInt64) -> LayoutNode { .leaf(pane(id)) }
        func split(_ direction: SplitDirection, _ a: LayoutNode, _ b: LayoutNode) -> LayoutNode {
            .split(id: nil, resourceID: nil, direction: direction, ratio: 0.5, a: a, b: b)
        }
        func column(_ id: UInt64, _ width: Double, _ layout: LayoutNode, dock: DockSnapshot? = nil) -> ColumnSnapshot {
            ColumnSnapshot(id: CmuxNextDaemon.ColumnID(rawValue: id), width: width, layout: layout, dock: dock)
        }
        let p1 = PaneSnapshot(id: pane(1), tabs: [moved]), p2 = PaneSnapshot(id: pane(2), tabs: [terminal])
        let p3 = PaneSnapshot(id: pane(3), tabs: [moved])
        let panes: [PaneSnapshot], columns: [ColumnSnapshot]
        if !after {
            (panes, columns) = ([p1, p2], [column(10, 1, split(.right, leaf(1), leaf(2)))])
        } else {
            switch drop {
            case .edgeSplit: (panes, columns) = ([p2, p3], [column(10, 1, split(.down, leaf(2), leaf(3)))])
            case .join: (panes, columns) = ([PaneSnapshot(id: pane(2), tabs: [terminal, moved])], [column(10, 1, leaf(2))])
            case .swap: (panes, columns) = ([p1, p2], [column(10, 1, split(.right, leaf(2), leaf(1)))])
            case .newColumn: (panes, columns) = ([p2, p3], [column(10, 0.5, leaf(2)), column(12, 0.5, leaf(3))])
            case .dock: (panes, columns) = ([p2, p3], [column(10, 1, leaf(2)), column(12, 0.3, leaf(3), dock: DockSnapshot(edge: .right, mode: .docked))])
            }
        }
        let screen = ScreenSnapshot(id: 1, layout: columns[0].layout, columns: columns, panes: panes)
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    // MARK: The drop and its frames

    /// The pane the tab lands in.
    var target: PaneController? {
        let id: UInt64 = switch kind {
        case .edgeSplit, .newColumn, .dock: 3
        case .join: 2
        case .swap: 1
        }
        return content.panes.values.first { $0.pane.handle == Self.pane(id) }
    }

    /// The drop's one turn: the daemon's tree after it, applied as the store's observation applies it; a join selects
    /// the tab it took, as its strip does.
    func drop() {
        store.apply(snapshot: Self.tree(kind, after: true, moved: Self.movedTab(dropped)))
        content.applyCurrent()
        if kind == .join, let target { target.applySelection(StripTabID(movedKey)) }
    }

    /// One display frame: the presentation's frame work, then the layout's frame tick and the frame's layout. True while
    /// a frame is asked for (the layout's, or the presentation's).
    @discardableResult
    func step() -> Bool {
        let presentation = frames.hasPending
        frames.fire()
        let asks = root.advanceFrame(Self.dt)
        content.contentView.layoutSubtreeIfNeeded()
        return asks || presentation || frames.hasPending
    }

    /// What the frame left for after its commit.
    func commit() {
        while !committed.isEmpty {
            let work = committed
            committed = []
            for item in work { item() }
        }
    }

    /// Each shown pane host's frame and its layer's frame, as text (a pane that moves changes one).
    func paneFrames() -> [String: String] {
        var frames: [String: String] = [:]
        for screen in root.screenViews.values where !screen.isHidden {
            for case let host as PaneHostView in screen.subviews where Self.shows(host) {
                frames[host.pane.rawValue] = "\(host.frame) layer \(host.layer?.frame ?? .zero) moves \(host.layer.map { !PaneCommitMotionTests.move(of: $0).animations.isEmpty } ?? false)"
            }
        }
        return frames
    }

    static func shows(_ host: PaneHostView) -> Bool {
        guard !host.isHidden, host.alphaValue > 0, host.frame.width >= 1, host.frame.height >= 1 else { return false }
        return host.layer.map { !$0.isHidden && $0.opacity > 0 } ?? true
    }

    /// Each pane that shows and does not paint its content now, with why.
    func blanks(_ when: String) -> [String] {
        var found: [String] = []
        for screen in root.screenViews.values where !screen.isHidden {
            for case let host as PaneHostView in screen.subviews where Self.shows(host) {
                let name = "\(when): \(host.pane.rawValue)"
                guard let pane = content.panes[host.pane] else {
                    // A pane that leaves shows to its motion's end: with its content, never its ground.
                    if (host.content as? PaneContentView)?.hostsContent != true { found.append("\(name) leaves and shows its ground, not its content") }
                    continue
                }
                found += unpainted(pane, host: host).map { "\(name) \($0)" }
            }
        }
        return found
    }

    private func unpainted(_ pane: PaneController, host: PaneHostView) -> [String] {
        let status = pane.surfaceStatus
        guard let selected = status.selectedTab else { return ["selects no tab"] }
        guard status.shownTab == selected else { return ["shows \(status.shownTab ?? "nothing") while \(selected) is selected"] }
        guard status.contentInstalled, let shown = pane.currentContent else { return ["shows its ground: \(selected)'s view is not in its content area"] }
        let view = shown.view
        var issues: [String] = []
        if view.window !== window { issues.append("\(shown.kind)'s view is not in the window") }
        if view.isHiddenOrHasHiddenAncestor { issues.append("\(shown.kind)'s view is hidden") }
        if host.contentRect.width >= 1, host.contentRect.height >= 1, view.bounds.width < 1 || view.bounds.height < 1 {
            issues.append("\(shown.kind)'s view has no area: \(view.bounds.size)")
        }
        if view.layer == nil { issues.append("\(shown.kind)'s view has no layer") }
        switch shown {
        case .terminal(let entry):
            let surface = entry.session.diagnostics
            if !surface.hasSurface || !surface.surfaceInHost || !surface.inWindow || surface.hidden || surface.layerSize.width < 1 || surface.layerSize.height < 1 {
                issues.append("the terminal does not draw: surface \(surface.hasSurface), in its host \(surface.surfaceInHost), in the window \(surface.inWindow), hidden \(surface.hidden), layer \(surface.layerSize)")
            }
        case .browser(let entry):
            if let page = (entry.tab as? any BrowserContentVisibilityReporting)?.contentVisibility, !page.isVisible {
                issues.append("the page does not draw: \(page.reason ?? "?")")
            } else if entry.tab.contentView.window == nil || entry.tab.contentView.isHiddenOrHasHiddenAncestor {
                issues.append("the page's view is not shown")
            }
        case .placeholder:
            issues.append("shows a placeholder")
        default:
            break
        }
        return issues
    }

    func close() {
        withExtendedLifetime((services, state)) {
            content.teardown()
            window.closeAfterTest()
        }
        for item in cleanup { item() }
    }
}
