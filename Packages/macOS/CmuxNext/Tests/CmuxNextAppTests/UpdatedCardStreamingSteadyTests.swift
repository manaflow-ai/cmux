import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-07: "this updated to nightly thing also sometimes flickers ... I assume it's just always sort of
/// like when you are, like, going through your thinking and your tool calls". A streaming turn changes the
/// sidebar's rows (status, step, last message, working) and its band items (badges, activity) many times a
/// second, and each change runs a sidebar render and a layout pass. These count what such a turn does to the
/// Updated card: its page view's frame, visibility, parent and paints, the card's own frame and visibility,
/// the pages it opens and the heights it hears. The card is never touched by a transcript delta: the flicker
/// was the card's page reloading at each web update (``WebSwapKeepsLoadedTreeTests``), which the island now
/// keeps from happening.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct UpdatedCardStreamingSteadyTests {
    /// The card's page: counts every frame change, visibility flip, reparenting and paint.
    final class CountingPage: NSView {
        var frames = 0, hides = 0, moves = 0, paints = 0, displays = 0
        nonisolated override var wantsUpdateLayer: Bool { true }
        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size { frames += 1 }
            super.setFrameSize(newSize)
        }
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            if newOrigin != frame.origin { frames += 1 }
            super.setFrameOrigin(newOrigin)
        }
        override var isHidden: Bool {
            didSet { if isHidden != oldValue { hides += 1 } }
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            moves += 1
        }
        override func updateLayer() { paints += 1 }
        override var needsDisplay: Bool {
            didSet { if needsDisplay { displays += 1 } }
        }
    }

    final class Island: SidebarSurfaceIsland {
        let page: CountingPage = {
            let page = CountingPage()
            page.wantsLayer = true
            return page
        }()
        var view: NSView { page }
        var contentHeight: CGFloat = 0
        var contentWidth: CGFloat = 0
        var onHeightChange: (() -> Void)?
        var onAction: (() -> Void)?
        var onDismiss: (() -> Void)?
        var closes = 0
        func close() { closes += 1 }
        func report(_ height: CGFloat) {
            contentHeight = height
            onHeightChange?()
        }
    }

    final class Surfaces: SidebarUpdateSurfaces {
        var islands: [Island] = []
        func island(_ kind: SidebarUpdateSurfaceKind) -> any SidebarSurfaceIsland {
            let island = Island()
            islands.append(island)
            return island
        }
    }

    static let card = SidebarUpdatedCard(title: "Updated", whatsNewTitle: "See What's New", dismissLabel: "Close")
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let rows = 40

    static func row(_ i: Int, step: Int) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID("w\(i)"), title: "Chat \(i)")
        // The chat beside the sidebar (w0) streams: its status, step, last message and working flag tick.
        if i == 0, step > 0 {
            row.status = step.isMultiple(of: 3) ? "Running tool" : "Thinking"
            row.agentStep = "step \(step)"
            row.lastMessage = "Reading file \(step)"
            row.agentWorking = !step.isMultiple(of: 7)
        }
        return row
    }

    static func sections(step: Int) -> [SidebarSection] {
        [SidebarSection(kind: .machine(machine), nodes: (0..<rows).map { .workspace(row($0, step: step)) })]
    }

    struct Counts: Equatable, CustomStringConvertible {
        var pageFrames = 0, pageHides = 0, pageMoves = 0, pagePaints = 0, pageDisplays = 0
        var cardFrames = 0, cardHides = 0, islandsOpened = 0, islandsClosed = 0, heightReports = 0, slotMoves = 0
        var description: String {
            "page frames \(pageFrames) hides \(pageHides) moves \(pageMoves) paints \(pagePaints) needsDisplay \(pageDisplays); "
                + "card frames \(cardFrames) hides \(cardHides); islands opened \(islandsOpened) closed \(islandsClosed); "
                + "height reports \(heightReports); slot springs \(slotMoves)"
        }
    }

    /// One streaming turn of `deltas` transcript deltas beside a shown Updated card, each a row patch and
    /// every third a band item change and a structural sections write, each followed by a render, a layout
    /// and a display pass, as a frame does. Returns what the card did during the turn.
    static func streamingTurn(deltas: Int) throws -> (Counts, rendersRun: Int) {
        let surfaces = Surfaces()
        let model = SidebarModel(sections: sections(step: 0), activeWorkspaceID: WorkspaceID("w0"))
        model.updatedCard = card
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        sidebar.updateSurfaces = surfaces
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = sidebar
        sidebar.renderNow()
        let island = try #require(surfaces.islands.first)
        island.report(64)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.displayIfNeeded()
        #expect(!sidebar.updatedCardView.isHidden, "the card shows before the turn")

        let host = sidebar.updatedCardView
        var counts = Counts()
        var heights = 0
        let report = host.onHeightChange
        host.onHeightChange = { heights += 1; report?() }
        let page = island.page
        let start = (page.frames, page.hides, page.moves, page.paints, page.displays)
        let cardFrame = host.frame, cardHidden = host.isHidden
        var lastFrame = cardFrame, lastHidden = cardHidden
        var renders = 0
        for step in 1...deltas {
            _ = model.patchWorkspaces([row(0, step: step)])
            if step.isMultiple(of: 3) {
                // A band item's badge and activity (ChiefSidebar status, unread count).
                var info = SidebarItemInfo(title: "Chief", symbol: "sparkles", badge: step % 5)
                info.activity = step.isMultiple(of: 2) ? .working(progress: nil) : .idle
                model.itemInfo = [LayoutItemID("chief"): info]
                model.sections = sections(step: step)
            }
            sidebar.renderNow()
            renders += 1
            sidebar.layoutSubtreeIfNeeded()
            sidebar.displayIfNeeded()
            if sidebar.cardSlotMotion.isMoving { counts.slotMoves += 1 }
            if host.frame != lastFrame { counts.cardFrames += 1; lastFrame = host.frame }
            if host.isHidden != lastHidden { counts.cardHides += 1; lastHidden = host.isHidden }
        }
        counts.pageFrames = page.frames - start.0
        counts.pageHides = page.hides - start.1
        counts.pageMoves = page.moves - start.2
        counts.pagePaints = page.paints - start.3
        counts.pageDisplays = page.displays - start.4
        counts.islandsOpened = surfaces.islands.count - 1
        counts.islandsClosed = surfaces.islands.reduce(0) { $0 + $1.closes }
        counts.heightReports = heights
        return (counts, renders)
    }

    @Test func aStreamingTurnNeverTouchesTheUpdatedCard() throws {
        let deltas = 300
        let (counts, renders) = try Self.streamingTurn(deltas: deltas)
        print("UPDATED-CARD-STREAMING deltas=\(deltas) renders=\(renders) \(counts)")
        #expect(renders == deltas)
        #expect(counts == Counts(), "a streaming turn touched the Updated card: \(counts)")
    }

    /// The App's island: its page keeps the web it loaded with, so a web update never reloads the card in place.
    @Test func theUpdatedCardsPageKeepsItsWebThroughAWebUpdate() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let island = UpdateSurfaceIsland(kind: .updated, services: services)
        defer { island.close() }
        let page = try #require(island.view as? PageWebView, "the card's surface is a page")
        #expect(WebBundleServedViews.shared.keepsLoadedTree(page.webKitView),
                "a web update would reload the Updated card's page in place (a blank frame at every merge)")
    }
}
