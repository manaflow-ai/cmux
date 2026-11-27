import AppKit
import CCmuxMotionFFI
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// The gooey tabs' strip (plans/cmux-next/gooey-tabs.md). Leo: "my argument is spunk ... built it out ultra fully and
/// rigorously so we can have some fun with it." Off stays pixel- and motion-identical to today; on, one selection blob
/// per strip runs one keyframed path animation per layer, retargets from what shows, holds still under reduced
/// motion, and plans in the same FFI calls at any tab count.
@MainActor @Suite(.serialized, .closesItsWindows) struct GooStripTests {
    /// A strip whose selected tab runs into the card (the flush corner pinned on, Default's density), with `level`.
    final class Harness {
        let window: NSWindow
        let strip: TabStripView
        let model: TabStripModel
        private let restore: () -> Void

        init(count: Int = 5, level: GooeyTabs) {
            let settings = DesignSettings.shared
            let (density, gooey) = (settings.densityTokens, settings.gooeyTabs)
            settings.densityTokens = DensityPreset.cozy.tokens
            let store = TunableStore.shared
            store.register([CornerFlush.tunable.descriptor])
            if !store.isActive { store.activate(file: nil) }
            let flush = store.set(CornerFlush.tunable.key, .choice(CornerFlush.goo.rawValue))
            settings.gooeyTabs = level
            restore = {
                _ = store.set(CornerFlush.tunable.key, flush)
                settings.gooeyTabs = gooey
                settings.densityTokens = density
            }
            let tabs = (0..<count).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }
            model = TabStripModel(tabs: tabs, selectedID: TabID("tab1"))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            strip = TabStripView(model: model)
            strip.dragsWindowFromEmptySpace = false
            window.contentView = strip
            layout()
        }

        func layout() {
            strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
            strip.needsLayout = true
            strip.layoutSubtreeIfNeeded()
        }

        func select(_ index: Int) {
            model.selectedID = TabID("tab\(index)")
            strip.syncFromModel()
            strip.layoutSubtreeIfNeeded()
            strip.applyFrames()
        }

        func close() {
            window.close()
            restore()
        }
    }

    private func requireFlush() throws {
        try #require(CornerFlush.current.isOn && DesignSettings.shared.tabBarPosition != .bottom,
                     "the pinned flush corner is off (compact density, or tabs at the bottom)")
    }

    private static func animations(_ goo: TabStripGoo) -> [CAKeyframeAnimation?] {
        [goo.fill, goo.shade, goo.dividerMask].map { $0.animation(forKey: TabStripGoo.key) as? CAKeyframeAnimation }
    }

    @Test func offDrawsTheFolderTabAsBefore() throws {
        let harness = Harness(level: .off)
        defer { harness.close() }
        try requireFlush()
        let strip = harness.strip
        let cell = try #require(strip.cells[TabID("tab1")])
        #expect(strip.goo == nil, "off makes no goo")
        #expect(cell.gooFill == nil && cell.runsIntoCard)
        let clip = try #require(strip.tabsClip.layer)
        let folder = try #require(cell.folderPath())
        let expected = TabStripView.map(folder, from: cell.layer, to: clip).intersection(CGPath(rect: clip.bounds, transform: nil))
        #expect(strip.selectedFolderPath(in: clip)?.boundingBoxOfPath == expected.boundingBoxOfPath,
                "off: the chrome's hole is the selected tab's folder, not the row")
        let before = strip.layer?.sublayers?.count
        harness.select(2)
        #expect(strip.goo == nil)
        #expect(strip.layer?.sublayers?.count == before, "off adds no layer")
        #expect(clip.sublayers?.contains { $0.animation(forKey: TabStripGoo.key) != nil } != true)
    }

    @Test func selectAddsOnePathAnimationPerBlobLayerSharingItsKeyframes() throws {
        let harness = Harness(level: .full)
        defer { harness.close() }
        try requireFlush()
        let goo = try #require(harness.strip.goo, "on, the strip makes its goo")
        goo.reducesMotion = false
        #expect(harness.strip.selectedFolderPath(in: harness.strip.layer!)?.boundingBoxOfPath == harness.strip.bounds,
                "on, the window's shade leaves the whole row to the strip")
        harness.select(3)
        let animations = Self.animations(goo).compactMap { $0 }
        try #require(animations.count == 3, "one path animation on the fill, the shade and the divider's mask")
        for layer in [goo.fill, goo.shade, goo.dividerMask] {
            #expect(layer.animationKeys() == [TabStripGoo.key], "one key per layer")
        }
        let (fill, shade, mask) = (animations[0], animations[1], animations[2])
        #expect(fill.keyPath == "path" && (fill.values?.count ?? 0) > 1)
        #expect(shade.keyTimes == fill.keyTimes && mask.keyTimes == fill.keyTimes)
        #expect(shade.duration == fill.duration && shade.beginTime == fill.beginTime)
        let holes = try #require(shade.values as? [CGPath]), masks = try #require(mask.values as? [CGPath])
        #expect(holes.count == masks.count && zip(holes, masks).allSatisfy { $0 === $1 },
                "the shade's hole and the divider's mask run the same keyframes")
        #expect(harness.strip.cells[TabID("tab3")]?.gooFill === goo.fill)
        #expect(harness.strip.cells[TabID("tab1")]?.gooFill == nil, "the blob left the old tab")
    }

    @Test func aRetargetMidFlightStartsWhereTheBlobShows() throws {
        let harness = Harness(level: .full)
        defer { harness.close() }
        try requireFlush()
        let goo = try #require(harness.strip.goo)
        goo.reducesMotion = false
        let t0 = CACurrentMediaTime()
        goo.now = { t0 }
        harness.select(4)
        let (left, right) = (try #require(goo.left), try #require(goo.right))
        let mid = t0 + 0.06
        let shownLeft = goo.planner.state(left, at: mid), shownRight = goo.planner.state(right, at: mid)
        goo.now = { mid }
        harness.select(0)
        let (newLeft, newRight) = (try #require(goo.left), try #require(goo.right))
        #expect(abs(newLeft.x0 - shownLeft.x) < 1e-6 && abs(newRight.x0 - shownRight.x) < 1e-6,
                "the new tracks start at the edges' state then, no jump")
        #expect(abs(newLeft.v0 - shownLeft.v) < 1e-6 && abs(newRight.v0 - shownRight.v) < 1e-6, "velocity kept")
        #expect(newLeft.start == mid && newRight.start == mid)
        #expect(goo.fill.animationKeys() == [TabStripGoo.key], "replaced, never stacked")
    }

    @Test func reducedMotionKeepsTheShapeAndDropsTheMotion() throws {
        let harness = Harness(level: .full)
        defer { harness.close() }
        try requireFlush()
        let goo = try #require(harness.strip.goo)
        goo.reducesMotion = true
        harness.select(3)
        #expect(Self.animations(goo).allSatisfy { $0 == nil }, "no movement")
        let blob = try #require(goo.blob)
        #expect(goo.fill.path != nil && goo.fill.path?.boundingBoxOfPath.minX ?? 0 <= blob.left,
                "the blob already rests on the new tab")
        let cell = try #require(harness.strip.cells[TabID("tab3")])
        #expect(cell.gooFill === goo.fill, "still gooey: the blob draws the folder")
    }

    @Test func manyTabsPlanInTheSameFFICallsAsAFew() throws {
        func calls(_ count: Int) throws -> Int {
            let harness = Harness(count: count, level: .subtle)
            defer { harness.close() }
            try requireFlush()
            let goo = try #require(harness.strip.goo)
            goo.reducesMotion = false
            goo.planner.resetCalls()
            harness.select(2)
            return goo.planner.calls
        }
        let few = try calls(5)
        #expect(few > 0, "a select plans")
        #expect(try calls(200) == few, "the plan never walks the tabs")
    }
}
