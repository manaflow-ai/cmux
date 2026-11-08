import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import Foundation
import Testing

/// The one text swap, in the app (`MotionGate.swapText`, `TextSwapMotion`) as in the webviews (`useTextSwap.ts`):
/// the same numbers from the one motion scale, the same keyframes, a Reduce Motion crossfade, nothing with motion
/// off, and only transform and opacity, so the view's frame never moves.
@MainActor @Suite(.serialized, .closesItsWindows) struct MotionTextSwapTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func theNumbersAreTheSharedMotionScales() throws {
        let data = try Data(contentsOf: Self.repoRoot.appending(path: "schemas/motion-scale/motion-scale.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let swap = try #require(json["textSwap"] as? [String: Any])
        #expect(swap["risePx"] as? Double == MotionScale.textSwapRise)
        #expect(swap["goneAt"] as? Double == MotionScale.textSwapGoneAt)
        #expect(swap["showFrom"] as? Double == MotionScale.textSwapShowFrom)
        #expect(swap["maxGhosts"] as? Int == MotionScale.textSwapMaxGhosts)
        #expect(TextSwapMotion.rise == 5 && TextSwapMotion.goneAt == 0.5 && TextSwapMotion.showFrom == 0.35)
    }

    @Test func thePolicyPicksRiseCrossfadeOrNothing() {
        let full = MotionPolicy(speed: .fast, reduceMotion: false, category: .sidebar)
        #expect(TextSwapMotion(policy: full) == TextSwapMotion(style: .rise, outDuration: MotionScale.micro, inDuration: MotionScale.standard))
        let slower = MotionPolicy(speed: .normal, reduceMotion: false, category: .sidebar)
        #expect(TextSwapMotion(policy: slower)?.inDuration == MotionScale.standard * 1.5)
        let reduced = TextSwapMotion(policy: MotionPolicy(speed: .fast, reduceMotion: true, category: .sidebar))
        #expect(reduced?.style == .crossfade)
        #expect((reduced?.inDuration ?? 1) <= MotionScale.micro, "Reduce Motion: a short crossfade")
        #expect(TextSwapMotion(policy: MotionPolicy(speed: .off, reduceMotion: false)) == nil)
        #expect(TextSwapMotion(policy: MotionPolicy(speed: .fast, reduceMotion: false, animationsEnabled: false)) == nil)
        #expect(TextSwapMotion(policy: MotionPolicy(speed: .fast, reduceMotion: false, disabledCategories: [.sidebar],
                                                    category: .sidebar)) == nil)
    }

    /// The web's keyframes: the old words fade out by `goneAt` while they rise the whole way; the new ones are
    /// unseen until `showFrom` and rise from below into place.
    @Test func thePosesFollowTheWebKeyframes() {
        let swap = TextSwapMotion(style: .rise, outDuration: MotionScale.micro, inDuration: MotionScale.standard)
        #expect(swap.outgoing(at: 0) == .init(opacity: 1, y: 0))
        let gone = swap.outgoing(at: swap.outDuration * 0.4) // eased progress past 0.5
        #expect(TextSwapMotion.ease(0.4) > TextSwapMotion.goneAt && gone.opacity == 0)
        #expect(abs(swap.outgoing(at: swap.outDuration).y + TextSwapMotion.rise) < 1e-9)
        #expect(swap.incoming(at: 0) == .init(opacity: 0, y: TextSwapMotion.rise))
        #expect(swap.incoming(at: swap.inDuration * 0.1).opacity == 0, "unseen before showFrom")
        let end = swap.incoming(at: swap.inDuration)
        #expect(abs(end.opacity - 1) < 1e-9 && abs(end.y) < 1e-9)
        // Interrupted: the old words leave from where the earlier new words stood.
        let start = TextSwapMotion.Pose(opacity: 0.4, y: 2)
        #expect(swap.outgoing(at: 0, from: start) == start)
        let crossfade = TextSwapMotion(style: .crossfade, outDuration: 0.08, inDuration: 0.08)
        #expect(crossfade.outgoing(at: 0.04).y == 0 && crossfade.incoming(at: 0.04).y == 0, "Reduce Motion: nothing moves")
    }

    static func swaps(_ layer: CALayer) -> Bool { layer.animationKeys()?.contains { $0.hasPrefix("cmux.textSwap") } == true }

    /// Waits, a few milliseconds at a time, until `done` or `deadline` seconds pass.
    static func until(deadline: TimeInterval, _ done: () -> Bool) async throws {
        let end = Date().addingTimeInterval(deadline)
        while !done(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// A label on screen.
    static func label() -> (MarqueeLabel, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 80), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        root.wantsLayer = true
        window.contentView = root
        let label = MarqueeLabel(gate: Motion.sidebar, frame: NSRect(x: 20, y: 30, width: 180, height: 18))
        label.stringValue = "Old words"
        root.addSubview(label)
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return (label, window)
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await !NSScreen.screens.isEmpty })
    func theSwapAnimatesOnlyPaintAndCleansUp() async throws {
        let previous = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = previous }
        let (label, window) = Self.label()
        defer { window.closeAfterTest() }
        let layer = try #require(label.layer)
        let frame = label.frame
        #expect(Motion.sidebar.swapText(in: label) { label.stringValue = "New words" })
        #expect(label.stringValue == "New words")
        #expect(label.frame == frame)
        #expect(layer.animation(forKey: MotionGate.textSwapOpacityKey) != nil)
        #expect(layer.animation(forKey: MotionGate.textSwapRiseKey) != nil)
        let ghosts = MotionGate.textSwapGhosts(of: layer)
        #expect(ghosts.count == 1)
        // Over the view: its anchor, position and size (its frame reads the end-state rise it leaves with).
        #expect(ghosts.first?.anchorPoint == layer.anchorPoint && ghosts.first?.position == layer.position
                    && ghosts.first?.bounds == layer.bounds, "the old words lie exactly over the view")
        #expect(layer.opacity == 1 && CATransform3DIsIdentity(layer.transform), "the model stays at rest")
        // A run of changes keeps at most two snapshots.
        for word in ["Third", "Fourth", "Fifth"] { Motion.sidebar.swapText(in: label) { label.stringValue = word } }
        #expect(MotionGate.textSwapGhosts(of: layer).count == MotionScale.textSwapMaxGhosts)
        Motion.sidebar.cancelTextSwap(in: label)
        #expect(MotionGate.textSwapGhosts(of: layer).isEmpty)
        #expect(layer.animationKeys()?.contains { $0.hasPrefix("cmux.textSwap") } != true)
        // Left to run, it ends on its own and takes its snapshot with it.
        Motion.sidebar.swapText(in: label) { label.stringValue = "Last" }
        // Awaited, not a spun run loop: the transaction's completion comes on the main queue this test runs on.
        try await Self.until(deadline: 1) { MotionGate.textSwapGhosts(of: layer).isEmpty && !Self.swaps(layer) }
        #expect(MotionGate.textSwapGhosts(of: layer).isEmpty)
        #expect(!Self.swaps(layer))
        #expect(label.frame == frame)
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await !NSScreen.screens.isEmpty })
    func reduceMotionCrossfadesAndMotionOffSwapsAtOnce() throws {
        let previous = Motion.reduceMotionOverride
        let speed = DesignSettings.shared.animationSpeed
        defer {
            Motion.reduceMotionOverride = previous
            DesignSettings.shared.animationSpeed = speed
        }
        let (label, window) = Self.label()
        defer { window.closeAfterTest() }
        let layer = try #require(label.layer)
        Motion.reduceMotionOverride = true
        #expect(Motion.sidebar.swapText(in: label) { label.stringValue = "Calm" })
        #expect(layer.animation(forKey: MotionGate.textSwapOpacityKey) != nil)
        #expect(layer.animation(forKey: MotionGate.textSwapRiseKey) == nil, "nothing rises under Reduce Motion")
        Motion.reduceMotionOverride = false
        DesignSettings.shared.animationSpeed = .off
        #expect(!Motion.sidebar.swapText(in: label) { label.stringValue = "Still" })
        #expect(label.stringValue == "Still")
        #expect(MotionGate.textSwapGhosts(of: layer).isEmpty, "motion off ends the earlier swap too")
        #expect(layer.animationKeys()?.contains { $0.hasPrefix("cmux.textSwap") } != true)
    }
}
