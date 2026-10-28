@testable import CmuxNextDesign
import QuartzCore
import Testing

/// Every shadowed layer casts from a `shadowPath` (MQ-shadow-path): a
/// shadow with no path makes Core Animation render the layer offscreen to find its alpha. These pin the
/// outline helpers: the path is the layer's rounded rect, it is rebuilt only when its inputs change, a
/// border's band leaves its inside clear, the strength matches the content shadow it replaces, and a
/// layer whose size springs gets the outline of every frame.
@MainActor @Suite struct ShadowOutlineTests {
    static let now: CFTimeInterval = 1000

    @Test func theCornerNeverPassesHalfTheShorterSide() {
        let capsule = ShadowOutline(size: CGSize(width: 40, height: 20), cornerRadius: 30)
        #expect(capsule.cornerRadius == 10)
        #expect(ShadowOutline(size: CGSize(width: -4, height: 20), cornerRadius: 6) == ShadowOutline(size: CGSize(width: 0, height: 20), cornerRadius: 0))
        #expect(capsule.path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 40, height: 20))
    }

    @Test func aLayerCastsFromItsOutlineAndRebuildsOnlyOnAChange() throws {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 120, height: 28)
        layer.cornerRadius = 6
        layer.cast(shadowPath: ShadowOutline(size: layer.bounds.size, cornerRadius: layer.cornerRadius))
        let first = try #require(layer.shadowPath)
        #expect(first == ShadowOutline(size: CGSize(width: 120, height: 28), cornerRadius: 6).path)
        layer.cast(shadowPath: ShadowOutline(size: layer.bounds.size, cornerRadius: layer.cornerRadius))
        #expect(layer.shadowPath === first, "an unchanged layout rebuilt the path")
        layer.bounds.size.width = 90
        layer.cast(shadowPath: ShadowOutline(size: layer.bounds.size, cornerRadius: layer.cornerRadius))
        #expect(layer.shadowPath?.boundingBoxOfPath.width == 90)
        #expect(layer.animation(forKey: "shadowPath") == nil, "setting the path animated it implicitly")
    }

    @Test func noPathCastsNothingRatherThanTheContent() {
        let layer = CALayer()
        layer.cast(shadowPathFor: [1]) { nil }
        #expect(layer.shadowPath?.isEmpty == true)
    }

    @Test func aBorderBandLeavesItsInsideClear() throws {
        let band = try #require(ShadowOutline(size: CGSize(width: 100, height: 60), cornerRadius: 8).band(width: 2))
        #expect(!band.contains(CGPoint(x: 50, y: 30)), "the ring's inside casts")
        #expect(band.contains(CGPoint(x: 50, y: 1)), "the ring's top edge does not cast")
        #expect(band.contains(CGPoint(x: 99, y: 30)), "the ring's trailing edge does not cast")
        #expect(!band.contains(CGPoint(x: 0.3, y: 0.3)), "the band casts outside its rounded corner")
        #expect(ShadowOutline(size: CGSize(width: 3, height: 60), cornerRadius: 8).band(width: 2) == nil)
    }

    @Test func thePathCastsAsStronglyAsTheFillDid() {
        #expect(ShadowOutline.opacity(0.2, under: CGColor(gray: 1, alpha: 0.5)) == Float(0.1))
        #expect(ShadowOutline.opacity(0.2, under: CGColor(gray: 0, alpha: 1)) == Float(0.2))
        #expect(ShadowOutline.opacity(0.2, under: nil) == 0)
    }

    /// A layer that springs from 80 to 120 wide: the follow's outlines start at 80 and end at the model's.
    @Test func aSpringingLayerFollowsItsSizeWithOutlines() throws {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 120, height: 28)
        layer.shadowOpacity = 0.1
        let grow = CABasicAnimation(keyPath: "bounds.size")
        grow.isAdditive = true
        grow.fromValue = NSValue(size: CGSize(width: -40, height: 0))
        grow.toValue = NSValue(size: .zero)
        grow.duration = 0.2
        grow.beginTime = Self.now
        layer.add(grow, forKey: "grow")
        layer.followShadowPath(now: Self.now) { ShadowOutline(size: $0, cornerRadius: 6).path }
        let follow = try #require(layer.animation(forKey: CALayer.shadowPathFollowKey) as? CAKeyframeAnimation)
        let values = try #require(follow.values)
        #expect(values.count > 2, "one outline per frame of the spring")
        let widths = values.map { CGPath.width(of: $0) }
        #expect(abs((widths.first ?? 0) - 80) < 0.5, "the follow starts at \(widths.first ?? 0), not where the layer shows")
        #expect(widths.last == 120, "the follow ends off the model outline")
        #expect(follow.calculationMode == .linear)

        layer.stopFollowingShadowPath()
        #expect(layer.animation(forKey: CALayer.shadowPathFollowKey) == nil)
    }

    /// A lift that ends fades its shadow out from a model strength of 0: while the fade runs the shadow
    /// shows, so a moving size still gets the outline of every frame; after it, nothing casts.
    @Test func aFadingShadowStillFollowsItsSize() throws {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 120, height: 28)
        layer.shadowOpacity = 0
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = 0.1
        fade.toValue = 0
        fade.duration = 0.15
        fade.beginTime = Self.now
        layer.add(fade, forKey: "shadowOpacity")
        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.isAdditive = true
        grow.fromValue = -40
        grow.toValue = 0
        grow.duration = 0.2
        grow.beginTime = Self.now
        layer.add(grow, forKey: "grow")
        #expect(layer.castsShadow(after: Self.now))
        layer.followShadowPath(now: Self.now) { ShadowOutline(size: $0, cornerRadius: 6).path }
        #expect(layer.animation(forKey: CALayer.shadowPathFollowKey) != nil, "a fading shadow casts from the end outline")
        #expect(!layer.castsShadow(after: Self.now + 0.15), "a faded shadow still counts as shown")
        layer.followShadowPath(now: Self.now + 0.16) { ShadowOutline(size: $0, cornerRadius: 6).path }
        #expect(layer.animation(forKey: CALayer.shadowPathFollowKey) == nil)
    }

    @Test func aStillOrShadowlessLayerAddsNoFollow() {
        let still = CALayer()
        still.bounds = CGRect(x: 0, y: 0, width: 50, height: 20)
        still.shadowOpacity = 0.1
        still.followShadowPath(now: Self.now) { ShadowOutline(size: $0, cornerRadius: 4).path }
        #expect(still.animation(forKey: CALayer.shadowPathFollowKey) == nil)

        let shadowless = CALayer()
        shadowless.bounds = CGRect(x: 0, y: 0, width: 50, height: 20)
        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.isAdditive = true
        grow.fromValue = -10
        grow.toValue = 0
        grow.duration = 0.2
        shadowless.add(grow, forKey: "grow")
        shadowless.followShadowPath(now: Self.now) { ShadowOutline(size: $0, cornerRadius: 4).path }
        #expect(shadowless.animation(forKey: CALayer.shadowPathFollowKey) == nil)
    }
}

private extension CGPath {
    /// The width of a keyframe value that holds a path.
    static func width(of value: Any) -> CGFloat {
        let object = value as AnyObject
        guard CFGetTypeID(object) == CGPath.typeID else { return -1 }
        return unsafeDowncast(object, to: CGPath.self).boundingBoxOfPath.width
    }
}
