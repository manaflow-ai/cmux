import AppKit
@testable import CmuxNextAgentCursor
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextMacScreen
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import QuartzCore
import Testing

/// chrome-parity p03-rendering-108 (MQ-shadow-path): every layer that casts a shadow casts it from a
/// `shadowPath`, so Core Animation never renders it offscreen to find its alpha (Chrome draws shadows
/// from the shape, `ui/compositor_extra/shadow.cc`). Each surface below cast from its content before:
/// a lifted tab and group chip, the pane rings' glows, the agent cursor's dart, tag and caption, and
/// the switch knobs of the sidebar, Page Info and Mac Screen.
@MainActor @Suite(.serialized) struct ShadowPathEverywhereTests {
    /// Every layer in `root`'s tree that casts a shadow and has no path.
    static func contentShadows(in root: CALayer) -> [CALayer] {
        var found: [CALayer] = []
        func walk(_ layer: CALayer) {
            if layer.shadowOpacity > 0, layer.shadowPath == nil { found.append(layer) }
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
        }
        walk(root)
        return found
    }

    static func casting(in root: CALayer) -> [CALayer] {
        var found: [CALayer] = []
        func walk(_ layer: CALayer) {
            if layer.shadowOpacity > 0 { found.append(layer) }
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
        }
        walk(root)
        return found
    }

    @Test func aLiftedTabCastsFromItsPill() throws {
        let cell = TabCell(item: TabItem(id: TabID("t"), title: "cmux"))
        cell.frame = CGRect(x: 0, y: 0, width: 180, height: 32)
        cell.isLifted = true
        #expect(Self.contentShadows(in: cell.layer).isEmpty)
        let path = try #require(cell.backgroundLayer.shadowPath)
        #expect(path.boundingBoxOfPath.size == cell.backgroundLayer.bounds.size, "the shadow is not the pill's outline")
        cell.frame = CGRect(x: 0, y: 0, width: 120, height: 32)
        #expect(cell.backgroundLayer.shadowPath?.boundingBoxOfPath.size == cell.backgroundLayer.bounds.size,
                "a resize left the old outline")
    }

    @Test func aLiftedGroupChipCastsFromItsPill() throws {
        let chip = TabGroupChipCell(group: TabGroupItem(id: "g", name: "Frontend"), memberCount: 3)
        chip.frame = CGRect(x: 0, y: 0, width: chip.slotWidth, height: 32)
        chip.isLifted = true
        #expect(Self.contentShadows(in: chip.layer).isEmpty)
        #expect(chip.pill.shadowPath?.boundingBoxOfPath.size == chip.pill.bounds.size)
    }

    /// A group with no color has a clear pill (`GroupTint.none`); its lift still casts, from the outline.
    @Test func aLiftedChipWithNoColorStillCasts() throws {
        let chip = TabGroupChipCell(group: TabGroupItem(id: "g", name: "Frontend", tint: .none), memberCount: 3)
        chip.frame = CGRect(x: 0, y: 0, width: chip.slotWidth, height: 32)
        chip.isLifted = true
        #expect(chip.pill.shadowOpacity > 0, "a clear pill lifts with no shadow")
        let path = try #require(chip.pill.shadowPath)
        #expect(path.boundingBoxOfPath.size == chip.pill.bounds.size)
        chip.isHovered = true
        #expect(chip.pill.shadowOpacity == Float(PopupStyle.elevation2.alpha), "a fill change moved the lift's strength")
    }

    /// Runs `body` with tab motion on (master switch, every category, Reduce Motion off), then puts
    /// the switches back.
    private func withMotion(_ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let (oldEnabled, oldDisabled, oldSpeed) = (design.animationsEnabled, design.disabledAnimationCategories, design.animationSpeed)
        Motion.reduceMotionOverride = false
        design.animationSpeed = .fast
        design.animationsEnabled = true
        design.disabledAnimationCategories = []
        defer {
            design.animationsEnabled = oldEnabled
            design.disabledAnimationCategories = oldDisabled
            design.animationSpeed = oldSpeed
            Motion.reduceMotionOverride = nil
        }
        try body()
    }

    /// The width of a follow keyframe (a `CGPath`).
    private static func width(_ value: Any) -> CGFloat {
        let object = value as AnyObject
        guard CFGetTypeID(object) == CGPath.typeID else { return -1 }
        return unsafeDowncast(object, to: CGPath.self).boundingBoxOfPath.width
    }

    /// The strip move of a tab's width, as `TabStripView.applyFrames` adds it: the new frame, the
    /// additive move of the root's size, then one layout that puts the parts on the path.
    private static func moveWidth(of cell: TabCell, to width: CGFloat, with move: TabStripMove) {
        let before = TabStripMove.snapshot(cell.layer, depth: 0, masks: false)
        cell.setFrame(CGRect(x: 0, y: 0, width: width, height: 32), laysOut: false)
        move.animate(from: before)
        cell.layoutLayers()
    }

    /// A tab grabbed while its width still moves (a new tab's grow), and one dropped while its width
    /// moves (a regrouped drop) whose lift fades out: the shadow casts from the outline of each frame,
    /// from the width it shows to the model's, and the follow ends with the width path.
    @Test func aTabLiftedOrDroppedMidWidthMoveCastsFromEachFramesOutline() throws {
        try withMotion {
            let motion = try #require(MotionMove.tween(.tabMove, in: Motion.tabs), "tab motion is off")
            #expect(Motion.tabs.duration(.lift) > 0, "the lift does not fade")
            let cell = TabCell(item: TabItem(id: TabID("t"), title: "cmux"))
            cell.frame = CGRect(x: 0, y: 0, width: 180, height: 32)
            let shown = cell.backgroundLayer.bounds.width
            Self.moveWidth(of: cell, to: 120, with: TabStripMove(generation: 1, motion: motion, closing: nil))
            let model = cell.backgroundLayer.bounds.width
            #expect(model < shown)
            #expect(cell.backgroundLayer.animation(forKey: CALayer.shadowPathFollowKey) == nil, "a tab with no shadow follows its width")

            cell.isLifted = true
            let follow = try #require(cell.backgroundLayer.animation(forKey: CALayer.shadowPathFollowKey) as? CAKeyframeAnimation,
                                      "a tab lifted mid-move casts from its end outline")
            let widths = (follow.values ?? []).map(Self.width)
            #expect(abs((widths.first ?? 0) - shown) < 1, "the follow starts at \(widths.first ?? 0), not the \(shown) the pill shows")
            #expect(widths.last == model, "the follow ends off the model outline")

            // The drop: the lift ends (its shadow fades out from a model of 0), then the settle moves the width.
            cell.isLifted = false
            #expect(cell.backgroundLayer.shadowOpacity == 0)
            #expect(cell.backgroundLayer.animation(forKey: CALayer.shadowPathFollowKey) != nil, "a fading lift lost its follow")
            Self.moveWidth(of: cell, to: 160, with: TabStripMove(generation: 2, motion: motion, closing: nil))
            #expect(cell.backgroundLayer.animation(forKey: CALayer.shadowPathFollowKey) != nil, "the settle's width move casts from its end outline")

            TabStripMove.cancel(cell.layer)
            #expect(cell.backgroundLayer.animation(forKey: CALayer.shadowPathFollowKey) == nil, "a cancelled move kept its follow")

            cell.isLifted = true
            Self.moveWidth(of: cell, to: 140, with: TabStripMove(generation: 3, motion: motion, closing: nil))
            #expect(cell.backgroundLayer.animation(forKey: CALayer.shadowPathFollowKey) != nil)
            for key in cell.layer.animationKeys() ?? [] where key.hasPrefix(TabStripMove.keyPrefix) { cell.layer.removeAnimation(forKey: key) }
            cell.layoutLayers()
            #expect(cell.backgroundLayer.animation(forKey: CALayer.shadowPathFollowKey) == nil, "the ended width path kept its follow")
        }
    }

    /// A chip lifted while a strip move springs its pill (a drag right after a collapse), and a lifted
    /// chip that a strip move resizes: the pill casts from each frame's outline.
    @Test func aLiftedChipFollowsItsSpringingPill() throws {
        try withMotion {
            let motion = try #require(MotionMove.tween(.tabMove, in: Motion.tabs), "tab motion is off")
            let chip = TabGroupChipCell(group: TabGroupItem(id: "g", name: "Frontend"), memberCount: 3)
            let full = CGRect(x: 0, y: 0, width: chip.slotWidth, height: 32)
            chip.frame = full
            let shown = chip.pill.bounds.width
            #expect(chip.move(to: CGRect(x: 0, y: 0, width: full.width - 30, height: 32), alpha: 1,
                              with: TabStripMove(generation: 1, motion: motion, closing: nil), scroll: 0))
            let model = chip.pill.bounds.width
            #expect(model < shown)
            #expect(chip.pill.animation(forKey: CALayer.shadowPathFollowKey) == nil, "a chip with no shadow follows its pill")

            chip.isLifted = true
            let follow = try #require(chip.pill.animation(forKey: CALayer.shadowPathFollowKey) as? CAKeyframeAnimation,
                                      "a chip lifted mid-move casts from its end outline")
            let widths = (follow.values ?? []).map(Self.width)
            #expect(abs((widths.first ?? 0) - shown) < 1, "the follow starts at \(widths.first ?? 0), not the \(shown) the pill shows")
            #expect(widths.last == model)

            TabStripMove.cancel(chip.layer)
            #expect(chip.pill.animation(forKey: CALayer.shadowPathFollowKey) == nil)
            #expect(chip.move(to: full, alpha: 1, with: TabStripMove(generation: 2, motion: motion, closing: nil), scroll: 0))
            #expect(chip.pill.animation(forKey: CALayer.shadowPathFollowKey) != nil, "a strip move of a lifted chip casts from its end outline")
        }
    }

    @Test func thePaneGlowsCastFromTheirBorders() throws {
        let design = DesignSettings.shared
        let saved = design.attention
        defer { design.attention = saved }
        var settings = AttentionSettings()
        settings.terminalRing = .glow
        design.attention = settings
        let view = PaneOverlayView()
        view.setFrameSize(NSSize(width: 400, height: 300))
        view.setShape(padding: 6, cornerRadius: 10, headerHeight: 0)
        var focusRing = FocusRingSettings()
        focusRing.style = .glow
        view.update(showsRing: true, dim: 0, focusRing: focusRing, border: PaneOverlayView.Border(shows: false),
                    attention: AttentionMark(generation: 1, quiet: true), attentionSettings: settings, animated: false)
        let layer = try #require(view.layer)
        #expect(!Self.casting(in: layer).isEmpty, "nothing glows")
        #expect(Self.contentShadows(in: layer).isEmpty)
        let glow = view.glowLayer
        let band = try #require(glow.shadowPath)
        let inside = CGPoint(x: glow.bounds.midX, y: glow.bounds.midY)
        #expect(!band.contains(inside), "the focus glow casts from inside its ring")
    }

    @Test func theAgentCursorCastsFromItsShapes() throws {
        let cursor = AgentCursorLayer(color: AgentCursorLayer.gray, name: "Claude · cmux", scale: 2)
        cursor.showCaption("ls -la", scale: 2)
        #expect(!Self.casting(in: cursor.root).isEmpty, "nothing casts")
        #expect(Self.contentShadows(in: cursor.root).isEmpty)
        #expect(cursor.nameTag.shadowPath?.boundingBoxOfPath.size == cursor.nameTag.bounds.size)
        #expect(cursor.caption.shadowPath?.boundingBoxOfPath.size == cursor.caption.bounds.size)
    }

    @Test func switchKnobsCastFromTheirOutlines() throws {
        let sidebar = SidebarUpdateToggle(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
        sidebar.fixedLook = .switchControl
        sidebar.layout()
        sidebar.updateLayer()
        let pageInfo = PageInfoToggle(frame: CGRect(origin: .zero, size: PageInfoStyle.toggleSize))
        pageInfo.layout()
        let macScreen = MacScreenSwitch(id: "s", label: "Share")
        macScreen.layout()
        for view in [sidebar, pageInfo, macScreen] as [NSView] {
            let layer = try #require(view.layer)
            #expect(!Self.casting(in: layer).isEmpty, "\(type(of: view)): nothing casts")
            #expect(Self.contentShadows(in: layer).isEmpty, "\(type(of: view)) casts from its content")
        }
    }
}
