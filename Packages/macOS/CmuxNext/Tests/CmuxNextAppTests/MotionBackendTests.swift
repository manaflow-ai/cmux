import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextWakeups
import Testing

/// The motion backend seam on the real hosts. With `motion.renderServer` off a
/// change calls no variant and moves exactly as before; on, each host's variants run once per change
/// turn, after the turn started its motions and before it lays anything out, and a motion a variant
/// takes gets no CPU first frame and no display frames.
@MainActor @Suite struct MotionBackendTests {
    typealias Strip = ColumnCloseScrollMotionTests.Strip

    final class Recorder {
        var begins = 0
        var taken = 0
        /// Whether the screen still held its presentation at each begin (nothing laid out yet).
        var heldAtBegin: [Bool] = []
    }

    /// A split/close variant that records its turns. Taking, it does to the CPU state what a real
    /// variant does: leaves the panes, dividers and the camera they carry at rest (its render-server
    /// springs are not modelled).
    struct RecordingClose: RenderServerMotion {
        typealias Host = ScreenContentView
        let recorder: Recorder
        var takes = false
        var kind: RenderMotionKind { .splitClose }
        func begin(on host: ScreenContentView, policy: MotionPolicy) -> MotionBackend {
            recorder.begins += 1
            recorder.heldAtBegin.append(host.heldPresentation != nil)
            guard takes, host.hasMotion || host.leadsFrame else { return .cpuStep }
            for key in Array(host.paneFrames.keys) { host.paneFrames[key]?.snap() }
            for key in Array(host.dividerFrames.keys) { host.dividerFrames[key]?.snap() }
            host.scroll.snap()
            host.scrollRidesFrames = false
            recorder.taken += 1
            return .renderServer
        }
    }

    /// A root variant of `kind` that records its turns and takes nothing.
    struct RecordingRoot: RenderServerMotion {
        typealias Host = LayoutRootView
        let recorder: Recorder
        let kind: RenderMotionKind
        func begin(on host: LayoutRootView, policy: MotionPolicy) -> MotionBackend {
            recorder.begins += 1
            return .cpuStep
        }
    }

    /// Three half-width columns, the last focused; with `variant`, the screen's registration is it alone.
    static func strip(registering variant: RecordingClose?, renderServer: Bool) -> Strip {
        let strip = Strip(ColumnCloseScrollMotionTests.columns(3), focused: "p3")
        if let variant { strip.screen.motionBackends = MotionBackends([variant], renderServer: { renderServer }) }
        return strip
    }

    /// The middle column closed: the third column slides left.
    static let closed: ScreenLayout = .columns([LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")),
                                                LayoutColumn(id: "c3", width: 0.5, root: .leaf("p3"))])

    /// The close, the layout's change turn only (the focus follows in its own).
    static func closeMiddleColumn(_ strip: Strip) {
        strip.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: closed)])
        strip.root.syncWithModel()
    }

    static func hostFrames(_ strip: Strip) -> [PaneID: CGRect] {
        Dictionary(uniqueKeysWithValues: (["p1", "p3"] as [PaneID]).map { ($0, strip.root.context.hosts[$0]?.frame ?? .null) })
    }

    @Test func theSwitchIsOffByDefault() {
        #expect(LayoutTunables.motionRenderServer.defaultValue == false)
        #expect(LayoutTunables.motionRenderServer.key == "motion.renderServer")
        #expect(LayoutTunables.all.contains { $0.key == "motion.renderServer" })
        // A kind registers in the task that moves it, behind the switch: the split.
        #expect(ScreenContentView.renderServerMotions.map(\.kind) == [.splitClose, .zoom])
        // The drop highlight.
        #expect(LayoutRootView.renderServerMotions.map(\.kind) == [.dropHighlight])
    }

    @Test func offACloseCallsNoVariantAndMovesExactlyAsBefore() {
        let recorder = Recorder()
        let seam = Self.strip(registering: RecordingClose(recorder: recorder, takes: true), renderServer: false)
        let plain = Self.strip(registering: nil, renderServer: false)
        Self.closeMiddleColumn(seam)
        Self.closeMiddleColumn(plain)
        #expect(plain.screen.hasMotion, "the close springs: the comparison is about motion")
        for _ in 0..<240 {
            #expect(Self.hostFrames(seam) == Self.hostFrames(plain))
            #expect(seam.screen.scroll.value == plain.screen.scroll.value)
            let moving = seam.step()
            #expect(plain.step() == moving)
            if !moving { break }
        }
        #expect(recorder.begins == 0)
    }

    @Test func onTheVariantRunsOncePerTurnBeforeAnythingIsLaidOut() {
        let recorder = Recorder()
        let seam = Self.strip(registering: RecordingClose(recorder: recorder), renderServer: true)
        let plain = Self.strip(registering: nil, renderServer: false)
        Self.closeMiddleColumn(seam)
        Self.closeMiddleColumn(plain)
        #expect(recorder.begins == 1, "one change, one turn")
        #expect(recorder.heldAtBegin == [true], "begin runs before the turn lays out")
        // A variant that leaves the close to the CPU: the turn lays out what it laid out before, once.
        #expect(Self.hostFrames(seam) == Self.hostFrames(plain))
        #expect(seam.screen.hasMotion == plain.screen.hasMotion)
        seam.model.focus("p1", notify: false)
        seam.root.syncWithModel()
        #expect(recorder.begins == 2)
    }

    @Test func aCloseTheRenderServerTakesHasNoCPUFirstFrameAndRestsInItsTurn() throws {
        let recorder = Recorder()
        let seam = Self.strip(registering: RecordingClose(recorder: recorder, takes: true), renderServer: true)
        Self.closeMiddleColumn(seam)
        let screen = seam.screen
        #expect(recorder.taken == 1)
        #expect(!screen.leadsFrame)
        #expect(!screen.hasMotion, "nothing left for the CPU to step")
        // Laid out once, at rest: each host has its rest size in the change's turn.
        for pane: PaneID in ["p1", "p3"] {
            let host = try #require(seam.root.context.hosts[pane])
            let rest = try #require(screen.paneFrames[pane]).targetRect.pixelEdges(screen.scale)
            #expect(abs(host.frame.width - rest.width) < 0.5 && abs(host.frame.height - rest.height) < 0.5)
        }
    }

    @Test func aTurnWhoseMotionTheRenderServerTookAsksForNoFrames() {
        let plain = Self.strip(registering: nil, renderServer: false)
        plain.screen.beginMotionTurn()
        let plainSprings = plain.screen.update(layout: Self.closed, animated: true)
        #expect(plainSprings, "the close springs: the comparison is about motion")
        #expect(plain.screen.endMotionTurn(needsFrames: plainSprings), "on the CPU the close needs frames")

        let recorder = Recorder()
        let seam = Self.strip(registering: RecordingClose(recorder: recorder, takes: true), renderServer: true)
        seam.screen.beginMotionTurn()
        let springs = seam.screen.update(layout: Self.closed, animated: true)
        #expect(springs)
        #expect(!seam.screen.endMotionTurn(needsFrames: springs), "the render server runs it: no display frames")
        #expect(recorder.taken == 1)
    }

    @Test func theRootsKindsBeginInTheirTurns() {
        let model = LayoutModel(screens: [LayoutScreen(id: "s1", name: "s1", layout: .splits(.leaf("a"))),
                                          LayoutScreen(id: "s2", name: "s2", layout: .splits(.leaf("b")))],
                                activeScreenID: "s1", focusedPane: "a")
        let provider = ColumnCloseScrollMotionTests.Panes()
        let root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        let screens = Recorder(), highlight = Recorder()
        root.motionBackends = MotionBackends([RecordingRoot(recorder: screens, kind: .screens),
                                              RecordingRoot(recorder: highlight, kind: .dropHighlight)],
                                             renderServer: { true })
        model.selectScreen("s2")
        root.syncWithModel()
        #expect(screens.begins == 1, "the screen switch's turn")
        #expect(highlight.begins == 1, "one turn calls every registered variant once")
        root.hideTabDragHighlight()
        #expect(highlight.begins == 2, "the highlight's own turn")
        #expect(screens.begins == 2)
    }
}
