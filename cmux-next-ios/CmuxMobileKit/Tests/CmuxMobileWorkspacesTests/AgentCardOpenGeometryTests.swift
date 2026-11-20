// The card and the page are both iOS views: these run in the iOS simulator test pass.
#if os(iOS)
import CmuxMobileDesign
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat
@testable import CmuxMobileWorkspaces

/// Leo (2026-11-17): "Preview causes layout shift bc preview vs display with composer is
/// different". An agent tab's grid card is its page's preview (`AgentChatPreview`, drawn at the
/// page's size and clipped to the card), and opening the card zooms it into the live page
/// (`AgentChatTranscript` above the tab's `AgentChatBottomStack`). Every message the card shows
/// must sit at the same page point on the live page, or the chat jumps as it opens.
///
/// Each case lays the live page out at the screen's size the way TabsKit does (the transcript
/// full screen, the composer stack 8 pt above the toolbar capsule, added once the zoom lands),
/// lays the card's preview out at the same size with the insets the grid gives it, and compares
/// each row's top, by row id, for every row the card shows.
@MainActor @Suite(.serialized) struct AgentCardOpenGeometryTests {
    final class Source: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static let at = Date(timeIntervalSince1970: 1_000_000)

    static let paragraph = "The merge check still has to rule on the unrelated iOS test failures. If they also fail on the base, "
        + "the check passes them and the queue lands the change; otherwise it holds the head and names the failing suites."

    /// One finished turn: a prompt, a tool call, a few paragraphs and a list.
    static func turn(_ id: String, paragraphs: Int) -> [AgentSessionEvent] {
        var events: [AgentSessionEvent] = [
            .userMessage(text: "What holds \(id)? Check the runners and the merge queue.", promptId: "p-\(id)", turnId: id, attachments: [], at: at),
            .turnStarted(turnId: id, at: at),
        ]
        var text = ""
        for index in 0 ..< paragraphs { text += "\(index + 1). \(paragraph)\n\n" }
        text += "- **Waiting for a Mac runner:** three checks are queued.\n- **Running now:** the iOS simulator build.\n\nThat is all for \(id)."
        events.append(.update(.agentMessageChunk(text: text, messageId: "m-\(id)")))
        events.append(.turnResult(turnId: id, status: .completed, errorText: nil, at: at))
        return events
    }

    static func store(turns: Int, paragraphs: Int) -> AgentChatStore {
        let store = AgentChatStore(source: Source())
        store.nextFrame = nil
        store.apply(.batch((0 ..< turns).flatMap { turn("t\($0)", paragraphs: paragraphs) }))
        return store
    }

    /// The tab's page as TabsKit draws it: the transcript full screen; the accessory row (the
    /// composer stack) only once the page is settled (`TabsView`: `zoomState.phase == .page`),
    /// its bottom 8 pt above the toolbar capsule.
    struct LivePage: View {
        let store: AgentChatStore
        let surface: AgentChatSurface
        let topInset: CGFloat
        let accessoryBottom: CGFloat
        let showsAccessory: Bool

        var body: some View {
            ZStack(alignment: .bottom) {
                AgentChatTranscript(store: store, surface: surface, topInset: topInset)
                    .background(Color.cmuxMobileBackground)
                if showsAccessory {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        AgentChatBottomStack(store: store, surface: surface)
                    }
                    .padding(.bottom, accessoryBottom)
                }
            }
            .ignoresSafeArea()
        }
    }

    /// The grid's card for the same tab (`WorkspaceTabsSource`'s agent card), not clipped:
    /// the card's picture is the top of this, scaled down.
    struct CardPage: View {
        let store: AgentChatStore
        let topInset: CGFloat
        let bottomInset: CGFloat

        var body: some View {
            AgentChatPreview(store: store, turns: store.turns, topInset: topInset, bottomInset: bottomInset)
                .ignoresSafeArea()
        }
    }

    @MainActor final class Harness {
        let window: UIWindow
        let host: UIHostingController<AnyView>
        init() {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874)) // iPhone 17 Pro
            host = UIHostingController(rootView: AnyView(EmptyView()))
            // The page in a container, as TabsKit hosts it: a zoom scales the page's view, never
            // the window's root (whose frame the window sets).
            let container = UIViewController()
            window.rootViewController = container
            container.addChild(host)
            host.view.frame = window.bounds
            host.view.autoresizingMask = []
            container.view.addSubview(host.view)
            host.didMove(toParent: container)
            window.makeKeyAndVisible()
        }
        var size: CGSize { window.bounds.size }
        var insets: EdgeInsets {
            let safe = window.safeAreaInsets
            return EdgeInsets(top: safe.top, leading: safe.left, bottom: safe.bottom, trailing: safe.right)
        }
        /// TabsKit's accessory padding: the toolbar capsule's top (`ToolbarLayout.make`: the
        /// bottom less max(safe bottom, 20) less the 48 pt control) plus 8.
        var accessoryBottom: CGFloat { max(insets.bottom, 20) + 48 + 8 }
        /// The card shows the page's top this tall (`AgentTabCard.cardAspect`).
        var cardHeight: CGFloat { min(size.height, size.width * AgentTabCard.cardAspect) }

        func show(_ view: some View) { host.rootView = AnyView(view) }

        /// Display frames, laid out each one (`frames` × 16 ms).
        func frames(_ count: Int, each: (() -> Void)? = nil) async {
            for _ in 0 ..< count {
                try? await Task.sleep(for: .milliseconds(16)) // test: one display frame of layout
                host.view.layoutIfNeeded()
                each?()
            }
        }
    }

    /// Row tops on the live page (page points: the page view's, the window's while it is not
    /// scaled), by row id: rows the page shows.
    static func liveRows(_ window: UIWindow) -> [String: CGRect] {
        guard let page = window.rootViewController?.children.first?.view,
              let list = find(ChatTranscriptCollectionView.self, in: window),
              let layout = list.collectionViewLayout as? ChatTranscriptLayout else { return [:] }
        var rows: [String: CGRect] = [:]
        for item in layout.items {
            guard let top = layout.top(of: item.id), let height = layout.height(of: item.id) else { continue }
            let frame = list.convert(CGRect(x: 0, y: top, width: list.bounds.width, height: height), to: page)
            if frame.maxY > 0, frame.minY < page.bounds.height { rows[item.id] = frame }
        }
        return rows
    }

    static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }

    /// Row tops in the card's preview laid out at the page's size (window points), by row id.
    static func previewRows(_ harness: Harness, store: AgentChatStore, topInset: CGFloat, bottomInset: CGFloat) async -> [String: CGRect] {
        var rows: [String: CGRect] = [:]
        PreviewRowProbe.report = { id, frame in rows[id] = frame }
        defer { PreviewRowProbe.report = nil }
        harness.show(CardPage(store: store, topInset: topInset, bottomInset: bottomInset))
        await harness.frames(10)
        return rows
    }

    struct Shift {
        /// Per row the card shows (top to bottom): live top less card top, in points.
        var rows: [(id: String, card: CGFloat, live: CGFloat)]
        var worst: CGFloat { rows.map { abs($0.live - $0.card) }.max() ?? .infinity }
        var line: String {
            rows.map { String(format: "%@ card %.1f live %.1f (%+.1f)", $0.id, $0.card, $0.live, $0.live - $0.card) }.joined(separator: "; ")
        }
    }

    /// The rows the card's part of the page shows (inside the card's height), on either side,
    /// compared by id: a row on only one side (the card blank where the page has a turn) counts
    /// as an infinite shift.
    static func shift(card: [String: CGRect], live: [String: CGRect], cardHeight: CGFloat) -> Shift {
        func inCard(_ frame: CGRect) -> Bool { frame.minY < cardHeight && frame.maxY > 0 }
        let ids = Set(card.filter { inCard($0.value) }.keys).union(live.filter { inCard($0.value) }.keys)
        let rows = ids.map { id in (id: id, card: card[id]?.minY ?? .infinity, live: live[id]?.minY ?? .infinity) }
        return Shift(rows: rows.sorted { min($0.card, $0.live) < min($1.card, $1.live) })
    }

    /// The tab was shown before: its surface measured its composer stack. The card drawn now and
    /// the page it opens to put every message the card shows at the same point.
    @Test(arguments: [(1, 1), (3, 4), (8, 0)])
    func aMeasuredTabsCardMatchesItsPage(turns: Int, paragraphs: Int) async throws {
        let harness = Harness()
        defer { harness.window.isHidden = true }
        let store = Self.store(turns: turns, paragraphs: paragraphs)
        let surface = AgentChatSurface()
        let topInset = harness.insets.top + 8
        harness.show(LivePage(store: store, surface: surface, topInset: topInset, accessoryBottom: harness.accessoryBottom, showsAccessory: true))
        await harness.frames(40)
        try #require(surface.bottomStackTop != nil, "the composer stack reported its frame")
        let live = Self.liveRows(harness.window)
        try #require(!live.isEmpty, "the live page laid out its rows")

        let bottomInset = WorkspaceTabPage.bottomInset(surface: surface)
        let card = await Self.previewRows(harness, store: store, topInset: topInset, bottomInset: bottomInset)
        let shift = Self.shift(card: card, live: live, cardHeight: harness.cardHeight)
        print("CARDOPENGEOMETRY measured turns=\(turns) page=\(harness.size) card=\(harness.cardHeight) worst=\(shift.worst): \(shift.line)")
        #expect(!shift.rows.isEmpty, "the card shows rows")
        #expect(shift.worst <= 0.5, "card vs page, per row: \(shift.line)")
    }

    /// The tab was never shown in this launch (a workspace opened on another tab): its surface
    /// has not measured a composer. Its card, and the page's first frames as the zoom opens it
    /// (no accessory yet) and after (the stack lands), put every message at the same point.
    @Test(arguments: [(1, 1), (3, 4), (8, 0)])
    func anUnmeasuredTabsCardMatchesItsPageAsItOpens(turns: Int, paragraphs: Int) async throws {
        let harness = Harness()
        defer { harness.window.isHidden = true }
        // Another tab measured the composer first (the workspace opened on it).
        let other = AgentChatSurface()
        let otherStore = Self.store(turns: 1, paragraphs: 1)
        let topInset = harness.insets.top + 8
        harness.show(LivePage(store: otherStore, surface: other, topInset: topInset, accessoryBottom: harness.accessoryBottom, showsAccessory: true))
        await harness.frames(30)

        let store = Self.store(turns: turns, paragraphs: paragraphs)
        let surface = AgentChatSurface()
        let bottomInset = WorkspaceTabPage.bottomInset(surface: surface)
        let card = await Self.previewRows(harness, store: store, topInset: topInset, bottomInset: bottomInset)

        // The zoom: the page is built and drawn with no accessory; then the accessory lands.
        harness.show(LivePage(store: store, surface: surface, topInset: topInset, accessoryBottom: harness.accessoryBottom, showsAccessory: false))
        var opening: [Shift] = []
        await harness.frames(12) { opening.append(Self.shift(card: card, live: Self.liveRows(harness.window), cardHeight: harness.cardHeight)) }
        harness.show(LivePage(store: store, surface: surface, topInset: topInset, accessoryBottom: harness.accessoryBottom, showsAccessory: true))
        var landed: [Shift] = []
        await harness.frames(30) { landed.append(Self.shift(card: card, live: Self.liveRows(harness.window), cardHeight: harness.cardHeight)) }

        let firstLaidOut = opening.first { $0.worst.isFinite } ?? opening.last!
        let settled = landed.last!
        let worstAny = (opening + landed).filter { $0.worst.isFinite }.map(\.worst).max() ?? .infinity
        print("CARDOPENGEOMETRY unmeasured turns=\(turns) page=\(harness.size) card=\(harness.cardHeight) first-frame worst=\(firstLaidOut.worst): \(firstLaidOut.line)")
        print("CARDOPENGEOMETRY unmeasured turns=\(turns) settled worst=\(settled.worst): \(settled.line)")
        print("CARDOPENGEOMETRY unmeasured turns=\(turns) worst over every frame=\(worstAny)")
        #expect(!settled.rows.isEmpty, "the card shows rows")
        #expect(settled.worst <= 0.5, "card vs settled page, per row: \(settled.line)")
        #expect(worstAny <= 0.5, "card vs the page in every frame as it opens (\(opening.count + landed.count) frames, worst \(worstAny)); first frame: \(firstLaidOut.line)")
    }

    /// The tab was shown (its composer measured), then the grid opened, then its card was
    /// tapped. TabsKit draws the page scaled down for the zoom, with no accessory, and full size
    /// once it lands. The page keeps every message the card shows in the card's place in every
    /// frame, scaled or not. Before cmux#45442's fix the page converted the composer's window
    /// point into the scaled page and drew the newest turn 146 pt low until the zoom landed
    /// (the fleet UI capture: "Both test suites pass" at 449 pt, then 299).
    @Test(arguments: [(1, 1), (3, 4)])
    func aShownTabsPageKeepsTheCardsPlaceWhileTheZoomScalesIt(turns: Int, paragraphs: Int) async throws {
        let harness = Harness()
        defer { harness.window.isHidden = true }
        let store = Self.store(turns: turns, paragraphs: paragraphs)
        let surface = AgentChatSurface()
        let topInset = harness.insets.top + 8
        harness.show(LivePage(store: store, surface: surface, topInset: topInset, accessoryBottom: harness.accessoryBottom, showsAccessory: true))
        await harness.frames(40)
        try #require(surface.stackMaxY != nil, "the composer stack reported its frame")

        // The grid: the card is drawn from the tab's surface.
        let bottomInset = WorkspaceTabPage.bottomInset(surface: surface)
        let card = await Self.previewRows(harness, store: store, topInset: topInset, bottomInset: bottomInset)

        // The zoom: the page, scaled from the card's size up to the screen's, no accessory.
        let page = harness.host.view!
        var frames: [Shift] = []
        func record() { frames.append(Self.shift(card: card, live: Self.liveRows(harness.window), cardHeight: harness.cardHeight)) }
        page.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        harness.show(LivePage(store: store, surface: surface, topInset: topInset, accessoryBottom: harness.accessoryBottom, showsAccessory: false))
        for step in 1 ... 8 {
            let scale = 0.4 + 0.6 * CGFloat(step) / 8
            page.transform = scale >= 1 ? .identity : CGAffineTransform(scaleX: scale, y: scale)
            await harness.frames(2) { record() }
        }
        // Landed: TabsKit adds the accessory.
        harness.show(LivePage(store: store, surface: surface, topInset: topInset, accessoryBottom: harness.accessoryBottom, showsAccessory: true))
        await harness.frames(20) { record() }

        let laidOut = frames.filter { $0.worst.isFinite }
        let worst = laidOut.map(\.worst).max() ?? .infinity
        let worstFrame = laidOut.max { $0.worst < $1.worst }
        print("CARDOPENGEOMETRY zoom turns=\(turns) frames=\(frames.count) worst=\(worst): \(worstFrame?.line ?? "-")")
        #expect(!laidOut.isEmpty, "the page laid out its rows")
        #expect(worst <= 0.5, "card vs the page while the zoom scales it (\(frames.count) frames, worst \(worst)): \(worstFrame?.line ?? "-")")
    }
}
#endif
