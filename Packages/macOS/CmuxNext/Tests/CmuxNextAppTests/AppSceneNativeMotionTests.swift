import AppKit
@testable import CmuxNextApps
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing

/// The SDK motion contract in the native renderer (`cmux-app-host/js/ABI.md` "Motion"): `animation`,
/// `scale`, `offset`, `blur`, `glow`, `gradient`, `trim`, `loop`, `transition` and the `Particles`
/// node parse from scene props, draw with Core Animation layers, and degrade to no motion (never a
/// crash) for values the renderer does not know. Reduce Motion stops loops and makes changes instant.
@MainActor @Suite(.serialized, .closesItsWindows) struct AppSceneNativeMotionTests {
    private static func scene(_ ops: [AppSceneOp]) -> AppSceneModel {
        let model = AppSceneModel()
        model.apply(ops)
        return model
    }

    /// A window with the scene; `shown` orders it on screen (Motion snaps a window with no screen).
    private static func host(_ model: AppSceneModel, shown: Bool = false, width: CGFloat = 260, tile: Bool = false) -> (NSWindow, AppSceneHostingView) {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: width, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if shown { window.orderFrontRegardless() }
        let hosting = AppSceneHostingView(model: model, bundleDirectory: nil)
        // A widget tile: only there does a node's `transition` run (AppSceneDefaultUnchangedTests).
        hosting.fillsBounds = tile
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private static func all(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { all(in: $0) } }
    private static func node(_ id: String, in root: NSView) -> AppSceneNodeNSView? {
        all(in: root).lazy.compactMap { $0 as? AppSceneNodeNSView }.first { $0.nodeID == id }
    }
    private static func layers(under layer: CALayer?) -> [CALayer] {
        guard let layer else { return [] }
        return [layer] + (layer.sublayers ?? []).flatMap { layers(under: $0) }
    }
    private static func keys(_ layer: CALayer?) -> [String] { layer?.animationKeys() ?? [] }
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// Runs `body` with Reduce Motion pinned (process-wide, so the suite is serialized).
    private static func withReduceMotion<T>(_ on: Bool, _ body: () throws -> T) rethrows -> T {
        let previous = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = on
        defer { Motion.reduceMotionOverride = previous }
        return try body()
    }

    // MARK: Parsing

    @Test func motionPropsParse() {
        func node(_ props: [String: AppJSON]) -> AppSceneNode { AppSceneNode(type: .circle, props: props) }
        #expect(node(["animation": "bouncy"]).motion == .bouncy)
        #expect(node(["animation": "snappy"]).motion == .timed(MotionScale.micro, .easeOut), "the motion scale's micro step, as the web")
        #expect(node(["animation": "smooth"]).motion == .timed(MotionScale.standard, .easeOut))
        #expect(node(["animation": "none"]).motion == nil)
        #expect(node(["animation": "move"]).motion == .spring(MotionSpring.move.base))
        #expect(node(["animation": ["spring": ["response": 100, "dampingFraction": 0.1]]]).motion
            == .spring(SpringParameters(response: 10, dampingFraction: 0.3)), "response and damping are clamped")
        #expect(node(["animation": ["duration": 0.01, "curve": "linear"]]).motion == .timed(0.05, .linear))
        #expect(node(["animation": ["duration": 1]]).motion == .timed(1, .easeOut))
        #expect(node(["animation": ["duration": 1, "curve": "wobble"]]).motion == nil, "an unknown curve is no animation")
        #expect(node(["animation": "teleport"]).motion == nil)
        #expect(node(["animation": 3]).motion == nil)

        #expect(node(["loop": ["effect": "spin"]]).loop == SceneLoop(effect: "spin"))
        #expect(node(["loop": ["effect": "spin"]]).loop?.period == 2)
        #expect(node(["loop": ["effect": "pulse", "period": 0.1]]).loop?.period == MotionLoop.shortestFlashCycle, "nothing flashes past 2 Hz")
        #expect(node(["loop": ["effect": "wiggle", "amount": 50]]).loop?.amount == 10)
        #expect(node(["loop": ["effect": "warp"]]).loop == nil)

        #expect(node(["transition": "pop"]).transition == .pop)
        #expect(node(["transition": "opacity"]).transition == .opacity)
        #expect(node(["transition": "move"]).transition == .move)
        #expect(node(["transition": "fade"]).transition == nil, "the base's names: opacity, not fade")
        #expect(node(["transition": "warp"]).transition == nil)

        #expect(node(["gradient": ["colors": ["#FF0000"]]]).gradient == nil, "one color is no gradient")
        #expect(node(["gradient": ["colors": ["primary", "#0000FF"]]]).gradient?.angle == 90)
        #expect(node(["trim": ["from": 0.8, "to": 0.2]]).trim.map { [$0.from, $0.to] } == [0.2, 0.2])
        #expect(node(["trim": ["to": 2]]).trim?.to == 1)
        #expect(node(["glow": ["radius": 4]]).glow == nil, "a glow needs a color")
        #expect(node(["glow": ["color": "warning"]]).glow?.radius == 8)
        #expect(node(["scale": -1]).scaleFactor == 0)
        #expect(node(["offset": ["x": 3]]).offset == CGPoint(x: 3, y: 0))
        #expect(node(["blur": 500]).blurRadius == 100)
    }

    @Test func particlesIsANodeType() {
        var scene = AppScene()
        scene.apply([.create(id: "p", type: "Particles", props: ["preset": "confetti"]), .root(id: "p")])
        #expect(scene["p"]?.type == .particles)
    }

    // MARK: Layers

    @Test func scaleOffsetAndRotationAreTheLayersOwnTransform() throws {
        let model = Self.scene([
            .create(id: "box", type: "Rectangle", props: ["frame": ["width": 40, "height": 20], "background": "primary",
                                                          "scale": 2, "offset": ["x": 10, "y": 5]]),
            .root(id: "box"),
        ])
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        let box = try #require(Self.node("box", in: root))
        let layer = try #require(box.layer)
        let space = SceneTransformSpace(layer: layer)
        #expect(CATransform3DEqualToTransform(layer.transform, space.transform(scale: 2, offset: CGPoint(x: 10, y: 5))))
        #expect(layer.transform.m11 == 2)
        #expect(box.frame.size == CGSize(width: 40, height: 20), "a scale does not move the frame")
        model.apply([.update(id: "box", props: ["scale": .null, "offset": .null, "rotation": 90])])
        root.layoutSubtreeIfNeeded()
        #expect(abs(layer.transform.m11) < 0.0001, "a quarter turn")
        model.apply([.update(id: "box", props: ["rotation": .null])])
        root.layoutSubtreeIfNeeded()
        #expect(CATransform3DIsIdentity(layer.transform))
    }

    @Test func hitTestingFollowsAnOffsetChildLayerTransform() throws {
        let model = Self.scene([
            .create(id: "stack", type: "ZStack", props: ["frame": ["width": 100, "height": 40]]),
            .create(id: "button", type: "Rectangle", props: ["frame": ["width": 20, "height": 20],
                                                                  "offset": ["x": 40], "onTap": true]),
            .children(id: "stack", children: ["button"]),
            .root(id: "stack"),
        ])
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        let stack = try #require(Self.node("stack", in: root))
        let button = try #require(Self.node("button", in: root))
        root.layoutSubtreeIfNeeded()

        #expect(button.frame == CGRect(x: 40, y: 10, width: 20, height: 20), "layout stays in the stack")
        #expect(stack.hitTest(NSPoint(x: 90, y: 20)) === button, "the offset drawing receives a tap")
        #expect(stack.hitTest(NSPoint(x: 50, y: 20)) == nil, "the old untransformed area does not")
    }

    @Test func trimDrawsPartOfAStrokedCircleFromTwelveOClock() throws {
        let model = Self.scene([
            .create(id: "ring", type: "Circle", props: ["size": 40, "stroke": "primary", "strokeWidth": 4, "trim": ["to": 0.25]]),
            .root(id: "ring"),
        ])
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        let ring = try #require(Self.node("ring", in: root))
        let shape = try #require(Self.layers(under: ring.layer).compactMap { $0 as? CAShapeLayer }.first { $0.path != nil })
        #expect(shape.strokeEnd == 0.25)
        #expect(shape.strokeStart == 0)
        var start: CGPoint?
        shape.path?.applyWithBlock { element in
            if start == nil, element.pointee.type == .moveToPoint { start = element.pointee.points[0] }
        }
        let first = try #require(start)
        #expect(abs(first.x - 20) < 0.01, "the outline starts on the vertical center line")
        #expect(abs(first.y - 2) < 0.01 || abs(first.y - 38) < 0.01, "at the top edge, inside the stroke")
    }

    @Test func clippedCutsTheChildrenButNotTheNodesOwnGlow() throws {
        let model = Self.scene([
            .create(id: "clock", type: "HStack", props: ["frame": ["width": 80, "height": 24], "cornerRadius": 6, "clipped": true,
                                                         "glow": ["color": "#FFD166", "radius": 8]]),
            .create(id: "digit", type: "Text", props: ["text": "4", "transition": "slide"]),
            .children(id: "clock", children: ["digit"]),
            .root(id: "clock"),
        ])
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        let clock = try #require(Self.node("clock", in: root))
        let digit = try #require(Self.node("digit", in: root))
        let clip = try #require(digit.superview as? AppSceneClipView, "a clipped node's children sit in its clip")
        #expect(clip.superview === clock)
        #expect(clip.layer?.masksToBounds == true)
        #expect(clip.layer?.cornerRadius == 6)
        #expect(clip.frame == clock.bounds)
        #expect(clock.layer?.masksToBounds == false, "the node's own glow is outside the clip")
        #expect(clock.layer?.shadowRadius == 8)
        model.apply([.update(id: "clock", props: ["clipped": .null])])
        root.layoutSubtreeIfNeeded()
        #expect(digit.superview === clock, "unclipped, the children go back into the node")
        #expect(!clock.subviews.contains { $0 is AppSceneClipView })
    }

    @Test func gradientAndGlowDraw() throws {
        let model = Self.scene([
            .create(id: "card", type: "VStack", props: ["frame": ["width": 100, "height": 40], "cornerRadius": 8,
                                                        "gradient": ["colors": ["#FF0000", "#0000FF"], "angle": 0],
                                                        "glow": ["color": "#FFD166", "radius": 12, "opacity": 0.8]]),
            .create(id: "orb", type: "Circle", props: ["size": 20, "gradient": ["colors": ["success", "warning"]],
                                                       "glow": ["color": "success", "radius": 6]]),
            .children(id: "card", children: ["orb"]),
            .root(id: "card"),
        ])
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        let card = try #require(Self.node("card", in: root))
        let layer = try #require(card.layer)
        let fill = try #require(layer.sublayers?.compactMap { $0 as? CAGradientLayer }.first)
        #expect(fill.colors?.count == 2)
        #expect(fill.frame == layer.bounds)
        #expect(abs(fill.startPoint.x - 0) < 0.001 && abs(fill.endPoint.x - 1) < 0.001, "0 degrees runs left to right")
        #expect(layer.shadowRadius == 12)
        #expect(abs(layer.shadowOpacity - 0.8) < 0.001)
        #expect(layer.shadowOffset == .zero)
        #expect(!layer.masksToBounds, "a glow is not clipped by the rounded corners")
        let orb = try #require(Self.node("orb", in: root))
        let orbFill = try #require(Self.layers(under: orb.layer).compactMap { $0 as? CAGradientLayer }.first)
        #expect(orbFill.mask is CAShapeLayer, "a shape's gradient shows through its outline")
        #expect(Self.layers(under: orb.layer).contains { $0.shadowRadius == 6 && $0.shadowOpacity == 1 })
    }

    @Test func blurIsAContentFilter() throws {
        let model = Self.scene([.create(id: "t", type: "Text", props: ["text": "soft", "blur": 4]), .root(id: "t")])
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        let text = try #require(Self.node("t", in: root))
        #expect(text.contentFilters.first?.name == "blur")
        #expect((text.contentFilters.first as? CIGaussianBlur)?.radius == 4)
        model.apply([.update(id: "t", props: ["blur": .null])])
        root.layoutSubtreeIfNeeded()
        #expect(text.contentFilters.isEmpty)
    }

    @Test func loopRunsInTheRenderServerAndStopsUnderReduceMotion() throws {
        try Self.withReduceMotion(false) {
            let model = Self.scene([
                .create(id: "list", type: "VStack", props: [:]),
                .create(id: "dot", type: "Circle", props: ["size": 20, "loop": ["effect": "pulse"]]),
                .create(id: "bar", type: "Capsule", props: ["frame": ["height": 10], "loop": ["effect": "shimmer"]]),
                .children(id: "list", children: ["dot", "bar"]),
                .root(id: "list"),
            ])
            let (window, root) = Self.host(model)
            defer { window.contentView = nil; window.close() }
            let dot = try #require(Self.node("dot", in: root))
            let pulse = try #require(dot.layer?.animation(forKey: "scene.loop"))
            #expect((pulse as? CAPropertyAnimation)?.isAdditive == true, "a loop adds to the node's own transform")
            #expect(pulse.repeatCount == .infinity)
            #expect((pulse as? CAPropertyAnimation)?.keyPath == "transform")
            let bar = try #require(Self.node("bar", in: root))
            #expect(Self.layers(under: bar.layer).contains { $0.animation(forKey: "scene.shimmer") != nil }, "a band crosses the bar")

            Motion.reduceMotionOverride = true
            root.layoutSubtreeIfNeeded()
            #expect(dot.layer?.animation(forKey: "scene.loop") == nil, "Reduce Motion stops loops")
            #expect(!Self.layers(under: bar.layer).contains { $0.animation(forKey: "scene.shimmer") != nil }, "and shimmer shows nothing")
        }
    }

    @Test func particlesFillTheirZStackAndBuildEveryPreset() throws {
        let model = Self.scene([
            .create(id: "z", type: "ZStack", props: [:]),
            .create(id: "fx", type: "Particles", props: ["preset": "snow"]),
            .create(id: "label", type: "Text", props: ["text": "Hello", "frame": ["height": 80]]),
            .children(id: "z", children: ["fx", "label"]),
            .root(id: "z"),
        ])
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        let fx = try #require(Self.node("fx", in: root) as? AppSceneParticlesNSView)
        let z = try #require(Self.node("z", in: root))
        #expect(fx.frame.size == z.bounds.size, "it fills the stack")
        #expect(z.bounds.height == 80, "and does not size it")
        #expect(fx.hitTest(NSPoint(x: 5, y: 5)) == nil, "it takes no input")
        for preset in AppSceneParticlesNSView.Preset.allCases {
            model.apply([.update(id: "fx", props: ["preset": .string(preset.rawValue), "colors": ["#FF0000", "primary"]])])
            root.layoutSubtreeIfNeeded()
            #expect(fx.field.emitterCells?.count == 2, "\(preset): one cell per color")
            #expect(fx.bursts.emitterCells?.count == 2)
            #expect(fx.bursts.birthRate == 0, "a burst only pulses")
        }
        model.apply([.update(id: "fx", props: ["preset": "lava"])])
        root.layoutSubtreeIfNeeded()
        #expect(fx.field.emitterCells == nil, "an unknown preset draws nothing")
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func burstFiresEachTimeTheCounterGrows() throws {
        try Self.withReduceMotion(false) {
            let model = Self.scene([.create(id: "fx", type: "Particles", props: ["preset": "confetti", "burst": 0, "frame": ["height": 120]]),
                                    .root(id: "fx")])
            let (window, root) = Self.host(model, shown: true)
            defer { window.contentView = nil; window.close() }
            let fx = try #require(Self.node("fx", in: root) as? AppSceneParticlesNSView)
            #expect(fx.burstHost.sublayers?.isEmpty ?? true, "the first value fires nothing")
            #expect(fx.field.birthRate == 0, "confetti emits only on a burst without a rate")
            guard fx.isEmitting else { return }
            model.apply([.update(id: "fx", props: ["burst": 1])])
            root.layoutSubtreeIfNeeded()
            let first = try #require(fx.burstHost.sublayers?.first, "a burst plays on an emitter of its own")
            #expect(first.animation(forKey: "scene.burst") != nil)
            model.apply([.update(id: "fx", props: ["burst": 2])])
            root.layoutSubtreeIfNeeded()
            #expect(fx.burstHost.sublayers?.count == 2, "a second burst leaves the first one's particles in flight")
        }
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func anAnimatedChangeStartsFromTheValueOnScreen() throws {
        try Self.withReduceMotion(false) {
            let model = Self.scene([
                .create(id: "list", type: "VStack", props: [:]),
                .create(id: "dot", type: "Circle", props: ["size": 20, "fill": "primary", "animation": "snappy"]),
                .create(id: "still", type: "Circle", props: ["size": 20, "fill": "primary"]),
                .children(id: "list", children: ["dot", "still"]),
                .root(id: "list"),
            ])
            let (window, root) = Self.host(model, shown: true)
            defer { window.contentView = nil; window.close() }
            try #require(window.screen != nil)
            let dot = try #require(Self.node("dot", in: root))
            let still = try #require(Self.node("still", in: root))
            model.apply([.update(id: "dot", props: ["opacity": 0.4, "scale": 1.5, "fill": "danger"]),
                         .update(id: "still", props: ["opacity": 0.4])])
            root.layoutSubtreeIfNeeded()
            let keys = Self.keys(dot.layer)
            #expect(keys.contains { $0.hasPrefix("scene.opacity.") })
            #expect(keys.contains { $0.hasPrefix("scene.transform.") })
            #expect(keys.compactMap { dot.layer?.animation(forKey: $0) }.allSatisfy { ($0 as? CAPropertyAnimation)?.isAdditive == true })
            #expect(Self.layers(under: dot.layer).contains { $0.animation(forKey: "scene.fillColor") != nil }, "the fill eases to its new tone")
            #expect(!Self.keys(still.layer).contains { $0.hasPrefix("scene.") }, "no `animation`, no motion")
            #expect(abs((dot.layer?.opacity ?? 0) - 0.4) < 0.001, "the model holds the new value")

            Motion.reduceMotionOverride = true
            model.apply([.update(id: "dot", props: ["opacity": 1, "scale": 1])])
            root.layoutSubtreeIfNeeded()
            #expect(Self.keys(dot.layer).filter { $0.hasPrefix("scene.opacity.") }.count <= 1, "Reduce Motion: the change is instant")
        }
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aTransitionPlaysOnEnterAndOnExitBeforeTheViewLeaves() throws {
        try Self.withReduceMotion(false) {
            let model = Self.scene([
                .create(id: "list", type: "VStack", props: [:]),
                .create(id: "first", type: "Text", props: ["text": "First", "transition": "pop"]),
                .create(id: "plain", type: "Text", props: ["text": "Plain"]),
                .children(id: "list", children: ["first", "plain"]),
                .root(id: "list"),
            ])
            let (window, root) = Self.host(model, shown: true, tile: true)
            defer { window.contentView = nil; window.close() }
            try #require(window.screen != nil)
            let first = try #require(Self.node("first", in: root))
            #expect(!Self.keys(first.layer).contains("scene.enter.transform"), "the first scene draws without entering")
            model.apply([.create(id: "card", type: "Text", props: ["text": "New!", "transition": "pop"]),
                         .children(id: "list", children: ["first", "card", "plain"])])
            root.layoutSubtreeIfNeeded()
            let card = try #require(Self.node("card", in: root))
            let plain = try #require(Self.node("plain", in: root))
            #expect(Self.keys(card.layer).contains("scene.enter.transform"))
            #expect(Self.keys(card.layer).contains("scene.enter.opacity"))
            model.apply([.children(id: "list", children: []), .remove(id: "card"), .remove(id: "plain")])
            root.layoutSubtreeIfNeeded()
            #expect(card.superview != nil, "kept on screen until its exit ends")
            #expect(Self.keys(card.layer).contains("scene.exit.opacity"))
            #expect(plain.superview == nil, "a node with no transition leaves at once")
        }
    }

    @Test func unknownMotionValuesDegradeToNoMotion() throws {
        let model = Self.scene([
            .create(id: "list", type: "VStack", props: ["animation": ["spring": "x"], "loop": ["effect": 5], "transition": 7,
                                                        "glow": ["color": 3], "gradient": ["colors": "red"], "blur": "x",
                                                        "scale": "big", "offset": 3]),
            .create(id: "ring", type: "Circle", props: ["size": 10, "stroke": "primary", "trim": ["to": "x"], "loop": "spin"]),
            .create(id: "fx", type: "Particles", props: ["preset": 9, "burst": "x", "rate": "fast", "colors": 4]),
            .children(id: "list", children: ["ring", "fx"]),
            .root(id: "list"),
        ])
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        let list = try #require(Self.node("list", in: root))
        #expect(CATransform3DIsIdentity(list.layer?.transform ?? CATransform3DIdentity))
        #expect(Self.keys(list.layer).isEmpty)
        #expect(list.contentFilters.isEmpty)
        let ring = try #require(Self.node("ring", in: root))
        #expect(Self.layers(under: ring.layer).compactMap { $0 as? CAShapeLayer }.first { $0.path != nil }?.strokeEnd == 1)
        let fx = try #require(Self.node("fx", in: root) as? AppSceneParticlesNSView)
        #expect(fx.field.emitterCells == nil)
    }

    // MARK: Particles choreography

    @Test func choreographyDrawsOneLayerPerDotAndHoldsItsStillUnderReduceMotion() throws {
        try Self.withReduceMotion(true) {
            let document = AppJSON.object(AppSceneChoreographyTests.fixture())
            let model = Self.scene([
                .create(id: "fx", type: "Particles", props: ["preset": "snow", "choreography": document, "trigger": "execute",
                                                             "frame": ["width": 60, "height": 40]]),
                .root(id: "fx"),
            ])
            let (window, root) = Self.host(model)
            defer { window.contentView = nil; window.close() }
            let fx = try #require(Self.node("fx", in: root) as? AppSceneParticlesNSView)
            let glyph = try #require(fx.glyph, "a valid choreography builds a glyph")
            #expect(fx.field.emitterCells == nil, "a valid choreography wins over the preset")
            #expect(glyph.dots.count == 4, "one layer per dot, up to particle.max")
            #expect(!glyph.isRunning, "Reduce Motion asks for no frames")
            #expect(glyph.dots.filter { !$0.isHidden }.count == 3, "the still: the trade's first frame")
            #expect(glyph.dots.allSatisfy { $0.animationKeys() == nil }, "no layer animates")
            // A new trigger reaches the running player; the same document keeps the glyph.
            model.apply([.update(id: "fx", props: ["trigger": "idle"])])
            root.layoutSubtreeIfNeeded()
            #expect(fx.glyph === glyph)
            // A document the player cannot read draws nothing and gives the preset back.
            model.apply([.update(id: "fx", props: ["choreography": ["$schema": "cmux.particles/2"]])])
            root.layoutSubtreeIfNeeded()
            #expect(fx.glyph == nil)
            #expect(fx.field.emitterCells?.isEmpty == false)
        }
    }
}
