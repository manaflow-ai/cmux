import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Testing

/// The sidebar's and the layout's Debug Settings looks follow through one FrameObservation per root
/// (p04-input-027), not one `withObservationTracking` hop per view: any number of changes in a turn
/// reach every view once, in the next frame, and nothing in the change's own turn.
@MainActor @Suite(.serialized) struct SidebarLookWatchTests {
    final class Follower: NSView, SidebarLookFollower {
        var told = 0
        func sidebarLookChanged() { told += 1 }
    }

    static let keys = [NotificationBadgeLook.tunable.key, SidebarGroupHeaderStyle.tunable.key, SidebarGroupPalette.tunable.key]

    @Test func manyLookChangesTellEveryFollowerOnceInTheNextFrame() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        defer { Self.keys.forEach { TunableStore.shared.set($0, nil) } }
        let rig = LookFrameRig()
        let root = NSView(), row = NSView(), badge = Follower(), header = Follower()
        root.addSubview(row)
        row.addSubview(badge)
        root.addSubview(header)
        let watch = SidebarLookWatch(root: root, on: rig.work)
        try #require(TunableStore.shared.set(Self.keys[0], NotificationBadgeLook.tone.tunableValue) != nil)
        try #require(TunableStore.shared.set(Self.keys[1], SidebarGroupHeaderStyle.line.tunableValue) != nil)
        try #require(TunableStore.shared.set(Self.keys[2], SidebarGroupPalette.theme.tunableValue) != nil)
        #expect(badge.told == 0 && header.told == 0, "a change told a view in its own turn (a hop per change)")
        rig.frame()
        #expect(badge.told == 1, "the nested badge heard \(badge.told) times for three changes")
        #expect(header.told == 1, "the header heard \(header.told) times for three changes")
        rig.frame()
        #expect(badge.told == 1 && header.told == 1, "a frame with no change told the views again")
        watch.cancel()
        rig.stop()
    }

    @Test func aBadgeDrawsTheNewLookAfterTheApply() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        defer { Self.keys.forEach { TunableStore.shared.set($0, nil) } }
        let rig = LookFrameRig()
        let root = NSView(), badge = UnreadBadgeView()
        root.addSubview(badge)
        badge.updateLayer()
        #expect(badge.look == NotificationBadgeLook.tunable.defaultValue)
        let watch = SidebarLookWatch(root: root, on: rig.work)
        try #require(TunableStore.shared.set(Self.keys[0], NotificationBadgeLook.outline.tunableValue) != nil)
        rig.frame()
        badge.updateLayer()
        #expect(badge.look == .outline, "the badge kept painting \(badge.look)")
        watch.cancel()
        rig.stop()
    }
}

@MainActor @Suite(.serialized) struct PaneAttentionLookWatchTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    @Test func oneWatchRecolorsEveryPaneInTheNextFrame() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(ChromeTunables.all)
        let key = AttentionHighlightLook.tunable.key
        defer { TunableStore.shared.set(key, nil) }
        let rig = LookFrameRig()
        let columns = [LayoutColumn(id: "c1", width: 1, root: .leaf("left")), LayoutColumn(id: "c2", width: 1, root: .leaf("right"))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "left")
        let provider = Panes()
        let root = LayoutRootView(model: model, contentProvider: provider, mainWork: rig.work)
        let chromes = [root.context.host(for: "left").chrome, root.context.host(for: "right").chrome]
        #expect(chromes.allSatisfy { $0.attentionLook == AttentionHighlightLook.tunable.defaultValue })
        try #require(TunableStore.shared.set(key, AttentionHighlightLook.flash.tunableValue) != nil)
        try #require(TunableStore.shared.set(key, AttentionHighlightLook.strong.tunableValue) != nil)
        #expect(chromes.allSatisfy { $0.attentionLook == AttentionHighlightLook.tunable.defaultValue },
                "a pane changed its look in the change's own turn")
        rig.frame()
        #expect(chromes.allSatisfy { $0.attentionLook == .strong }, "a pane kept its look after the frame")
        rig.stop()
    }
}

/// The app's one main-thread scheduler on a hand-fired link, kept running by a frame client so a
/// change waits for the next ``frame()``.
@MainActor final class LookFrameRig {
    let work: MainWorkScheduler
    private let clock = LookFrameClock()
    private var timestamp: Double = 0
    private var keeper: FrameClient?

    init() {
        let clock = self.clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ -> (any FrameLink)? in
            LookFrameLink()
        }
        let keeper = FrameClient(owner: "test.lookKeeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
        self.keeper = keeper
    }

    /// One display frame, 17 ms after the last.
    func frame() {
        clock.advance(ms: 17)
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    func stop() {
        keeper?.deactivate()
    }
}

@MainActor private final class LookFrameClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: UInt64) { now += ms * 1_000_000 }
}

@MainActor private final class LookFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
