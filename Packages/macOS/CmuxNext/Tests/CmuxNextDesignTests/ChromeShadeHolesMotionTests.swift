@testable import CmuxNextDesign
import QuartzCore
import Testing

/// The shade's hole under a folder tab moves with the folder (design/selected-is-foreground.md, motion):
/// while the tab's width or slot moves, the mask's base plays the folder's samples instead of jumping to
/// the end; at rest, or on a selection change (a fade), it carries no motion.
@MainActor @Suite struct ChromeShadeHolesMotionTests {
    private func base(_ holes: ChromeShadeHoles) -> CALayer? { holes.mask.sublayers?.first }

    @Test func aMovingFolderKeyframesItsHole() throws {
        let holes = ChromeShadeHoles()
        holes.layout(bounds: CGRect(x: 0, y: 0, width: 400, height: 100))
        let now = CACurrentMediaTime()
        let start = CGPath(rect: CGRect(x: 10, y: 0, width: 100, height: 40), transform: nil)
        let end = CGPath(rect: CGRect(x: 60, y: 0, width: 140, height: 40), transform: nil)
        let motion = FolderMotion(times: [now, now + 0.1, now + 0.2], paths: [start, start, end])
        holes.set(ObjectIdentifier(holes), path: end, animated: false, motion: motion)
        let animation = try #require(base(holes)?.animation(forKey: ChromeShadeHoles.motionKey) as? CAKeyframeAnimation)
        #expect(animation.keyPath == "path")
        #expect((animation.values?.count ?? 0) >= 2)
    }

    @Test func aFolderAtRestOrFadingHasNoMotion() {
        let holes = ChromeShadeHoles()
        holes.layout(bounds: CGRect(x: 0, y: 0, width: 400, height: 100))
        let key = ObjectIdentifier(holes)
        let path = CGPath(rect: CGRect(x: 10, y: 0, width: 100, height: 40), transform: nil)
        holes.set(key, path: path, animated: false)
        #expect(base(holes)?.animation(forKey: ChromeShadeHoles.motionKey) == nil)
        let now = CACurrentMediaTime()
        let other = CGPath(rect: CGRect(x: 120, y: 0, width: 100, height: 40), transform: nil)
        holes.set(key, path: other, animated: true, motion: FolderMotion(times: [now, now + 0.2], paths: [path, other]))
        #expect(base(holes)?.animation(forKey: ChromeShadeHoles.motionKey) == nil)
    }

    /// A -> B -> A inside one fade retargets A's closing hole: no second patch opens under its fade
    /// (Codex at 2b1e6839, F2).
    @Test func reselectingInsideTheFadeReopensTheClosingHole() {
        let holes = ChromeShadeHoles()
        holes.layout(bounds: CGRect(x: 0, y: 0, width: 400, height: 100))
        let key = ObjectIdentifier(holes)
        let a = CGPath(rect: CGRect(x: 10, y: 0, width: 100, height: 40), transform: nil)
        let b = CGPath(rect: CGRect(x: 120, y: 0, width: 100, height: 40), transform: nil)
        holes.set(key, path: a, animated: false)
        holes.set(key, path: b, animated: true)
        #expect(holes.closingCount == 1)
        holes.set(key, path: a, animated: true)
        // A is open again on its own patch; only B is closing. Base + A + B.
        #expect(holes.closingCount == 1)
        #expect(holes.mask.sublayers?.count == 3)
    }
}
