import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import Foundation
import QuartzCore
import Testing
import os

/// Spike p03-rendering-016 (rendering-DESIGN.md R2, "Spike 016"): which layer carries a pane's render-server
/// springs. Two candidates: the pane host's own backing layer (`PaneHostView`), and a dedicated motion container
/// view around the host that only motion code sizes and that keeps the springs it runs. Each test springs a pane
/// with additive springs (mass 1, critically damped, initial velocity 0: the RenderSpring shape), disturbs it,
/// then reads the presented geometry at 25, 50 and 75 % of the way. The container's results are asserted; the
/// backing layer's are printed as `render-motion-spike` lines for the doc's results table.
@MainActor @Suite(.serialized)
struct RenderMotionSpikeTests {
    /// Points a presented edge may miss the spring's value by, past one frame of travel either side of the read.
    static let tolerance: CGFloat = 0.5

    static func hasDisplay() -> Bool { NSScreen.main != nil }

    static func hasTwoDisplays() -> Bool { NSScreen.screens.count > 1 }

    /// The presented geometry still follows its springs after `event`, at 25, 50 and 75 % of the way.
    @Test(.enabled("needs a display: presented values come from committed animations") { await RenderMotionSpikeTests.hasDisplay() },
          arguments: SpikeLayer.allCases, SpikeEvent.allCases)
    func springsSurvive(_ layer: SpikeLayer, _ event: SpikeEvent) async throws {
        let rig = try SpikeRig(size: CGSize(width: 900, height: 620))
        defer { rig.close() }
        let pane = rig.addPane(layer, frame: CGRect(x: 40, y: 40, width: 240, height: 180))
        let spring = SpikeSpring(omega: 2)
        pane.spring(to: CGRect(x: 240, y: 160, width: 400, height: 280), with: spring)
        rig.disturb(event, pane: pane)
        let errors = try await rig.sample(pane, spring: spring)
        Self.report(layer, event: event.rawValue, errors: errors, pane: pane)
        if layer == .motionContainer {
            #expect(errors.allSatisfy { $0 <= Self.tolerance }, "\(event): off its spring by \(errors) pt at 25/50/75 %")
        }
    }

    /// The window moves to another display mid-spring.
    @Test(.enabled("needs two displays") { await RenderMotionSpikeTests.hasTwoDisplays() }, arguments: SpikeLayer.allCases)
    func springsSurviveADisplayMove(_ layer: SpikeLayer) async throws {
        let rig = try SpikeRig(size: CGSize(width: 900, height: 620))
        defer { rig.close() }
        let pane = rig.addPane(layer, frame: CGRect(x: 40, y: 40, width: 240, height: 180))
        let spring = SpikeSpring(omega: 2)
        pane.spring(to: CGRect(x: 240, y: 160, width: 400, height: 280), with: spring)
        let other = try #require(NSScreen.screens.first { $0 != rig.window.screen })
        rig.window.setFrameOrigin(NSPoint(x: other.visibleFrame.minX + 40, y: other.visibleFrame.minY + 40))
        try #require(rig.window.screen == other, "the window did not move to the other display")
        let errors = try await rig.sample(pane, spring: spring)
        Self.report(layer, event: "displayMove", errors: errors, pane: pane)
        if layer == .motionContainer {
            #expect(errors.allSatisfy { $0 <= Self.tolerance }, "display move: off its spring by \(errors) pt")
        }
    }

    /// The window enters full screen mid-spring (a slow spring, so its 25 % mark comes after the transition).
    /// A test runner without a running NSApplication may never enter full screen: that is a known issue, not
    /// a result.
    @Test(.enabled("needs a display") { await RenderMotionSpikeTests.hasDisplay() }, arguments: SpikeLayer.allCases)
    func springsSurviveFullScreen(_ layer: SpikeLayer) async throws {
        let rig = try SpikeRig(size: CGSize(width: 900, height: 620))
        defer { rig.close() }
        let pane = rig.addPane(layer, frame: CGRect(x: 40, y: 40, width: 240, height: 180))
        let spring = SpikeSpring(omega: 0.35)
        pane.spring(to: CGRect(x: 240, y: 160, width: 400, height: 280), with: spring)
        var entered = false
        await withKnownIssue("a swift test runner may not enter full screen", isIntermittent: true) {
            entered = await rig.toggleFullScreen(entering: true)
            try #require(entered, "the window did not enter full screen within 5 s")
        }
        guard entered else { return }
        let errors = try await rig.sample(pane, spring: spring)
        _ = await rig.toggleFullScreen(entering: false)
        Self.report(layer, event: "fullScreen", errors: errors, pane: pane)
        if layer == .motionContainer {
            #expect(errors.allSatisfy { $0 <= Self.tolerance }, "full screen: off its spring by \(errors) pt")
        }
    }

    /// A CALayerHost or an IOSurface leaf larger than the pane is cut to the rounded rect the pane presents, at
    /// rest and mid-spring (a near-frozen spring holds the pane 120 x 80 pt smaller than its rest while the
    /// window server captures it). Pixels come from the window server, so CALayerHost content counts.
    @Test(.enabled("needs a display") { await RenderMotionSpikeTests.hasDisplay() },
          arguments: SpikeLayer.allCases, SpikeLeaf.allCases)
    func leavesClipToThePresentedRoundedRect(_ layer: SpikeLayer, _ leaf: SpikeLeaf) async throws {
        let rig = try SpikeRig(size: CGSize(width: 360, height: 260), styleMask: [.borderless])
        defer { rig.close() }
        let rest = CGRect(x: 40, y: 40, width: 280, height: 180)
        let pane = rig.addPane(layer, frame: rest, cornerRadius: 14)
        try rig.addLeaf(leaf, to: pane)
        for midSpring in [false, true] {
            if midSpring {
                pane.springSize(from: CGSize(width: rest.width - 120, height: rest.height - 80), with: SpikeSpring(omega: 0.02))
            }
            await rig.wait(untilMediaTime: CACurrentMediaTime() + 0.15)
            let shown = try #require(pane.presentedFrameInWindow(), "no presentation layer")
            let image = try await rig.window.screenshotImage()
            let pixels = try #require(SpikePixels(image, window: rig.window.frame.size))
            let probes = SpikeClipProbe.probes(in: shown)
            let wrong = probes.filter { pixels.isRed(at: $0.point) != $0.red }.map(\.name)
            print("render-motion-spike clip layer=\(layer.rawValue) leaf=\(leaf.rawValue) midSpring=\(midSpring) " +
                  "shown=\(shown) wrong=\(wrong.isEmpty ? "none" : wrong.joined(separator: ","))")
            if layer == .motionContainer {
                #expect(wrong.isEmpty, "\(leaf) \(midSpring ? "mid-spring" : "at rest") in \(shown): wrong at \(wrong)")
            }
        }
    }

    /// 12 masked panes, each with an IOSurface leaf and a CALayerHost leaf, spring between two grids for
    /// `CMUX_RENDER_SPIKE_ROUNDS` rounds (3 by default). The main thread lays nothing out while they move; each
    /// round is a Points of Interest interval (subsystem com.cmuxterm.render-motion-spike), so an xctrace
    /// Animation Hitches recording of the run gives each candidate's render-server hitches.
    @Test(.enabled("needs a display") { await RenderMotionSpikeTests.hasDisplay() }, arguments: SpikeLayer.allCases)
    func twelveMaskedPanesSpringWithNoMainWork(_ layer: SpikeLayer) async throws {
        let rig = try SpikeRig(size: CGSize(width: 1200, height: 800))
        defer { rig.close() }
        let grids = [SpikeRig.gridFrames(columns: [1, 1, 1, 1], in: rig.screen.bounds),
                     SpikeRig.gridFrames(columns: [2, 1, 0.5, 0.5], in: rig.screen.bounds)]
        let panes = grids[0].map { rig.addPane(layer, frame: $0, cornerRadius: 10, stripClip: true) }
        for pane in panes {
            try rig.addLeaf(.ioSurface, to: pane)
            try rig.addLeaf(.layerHost, to: pane)
        }
        await rig.wait(untilMediaTime: CACurrentMediaTime() + 0.1)
        let rounds = max(1, ProcessInfo.processInfo.environment["CMUX_RENDER_SPIKE_ROUNDS"].flatMap(Int.init) ?? 3)
        let spring = SpikeSpring(omega: 14)
        let signposter = OSSignposter(subsystem: "com.cmuxterm.render-motion-spike", category: .pointsOfInterest)
        print("render-motion-spike hitch-scenario layer=\(layer.rawValue) pid=\(ProcessInfo.processInfo.processIdentifier) " +
              "rounds=\(rounds) settle_ms=\(Int(spring.settlingTime * 1000))")
        var lateLandings: [Double] = []
        for round in 0..<rounds {
            let targets = grids[(round + 1) % 2]
            let state = signposter.beginInterval("springs", id: signposter.makeSignpostID(), "\(layer.rawValue, privacy: .public)")
            let begin = CACurrentMediaTime()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                CATransaction.begin()
                CATransaction.setCompletionBlock { continuation.resume() }
                for (pane, target) in zip(panes, targets) { pane.spring(to: target, with: spring) }
                CATransaction.commit()
            }
            signposter.endInterval("springs", state)
            lateLandings.append((CACurrentMediaTime() - begin - spring.settlingTime) * 1000)
            // Main work while the panes moved: every frame and layout set at the round's start, none after it.
            let layouts = panes.map { $0.layoutsSinceSpring }
            #expect(layouts.allSatisfy { $0 == 0 }, "round \(round): layouts during the spring \(layouts)")
        }
        let sorted = lateLandings.sorted()
        print("render-motion-spike hitch-scenario layer=\(layer.rawValue) late_landing_ms_p50=\(Self.format(sorted[sorted.count / 2])) " +
              "late_landing_ms_max=\(Self.format(sorted.last ?? 0))")
    }

    private static func report(_ layer: SpikeLayer, event: String, errors: [CGFloat], pane: SpikePane) {
        print("render-motion-spike layer=\(layer.rawValue) event=\(event) p25=\(format(errors[0])) p50=\(format(errors[1])) " +
              "p75=\(format(errors[2])) layerReplaced=\(pane.layerReplaced)")
    }

    private static func format(_ value: Double) -> String {
        value.isFinite ? String(format: "%.2f", value) : "lost"
    }
}

/// The layer that carries a pane's springs.
nonisolated enum SpikeLayer: String, CaseIterable, Sendable {
    /// `PaneHostView`'s backing layer, the layer AppKit writes from the host's frame.
    case backingLayer
    /// `SpikeMotionContainerView`'s backing layer, around the host.
    case motionContainer
}

/// What happens to the pane while it springs.
nonisolated enum SpikeEvent: String, CaseIterable, Sendable {
    /// Nothing happens: the control.
    case control
    /// A layout pass over the window, a content frame change, and the zero-length animator group the layout sets
    /// rest frames through (the springing view's frame set again to its rest).
    case appKitLayout
    /// The pane's superview moves and grows, then the window grows.
    case ancestorSetFrame
    /// The springing view's `wantsLayer` goes off and on.
    case wantsLayer
    /// The superview's `wantsLayer` goes off and on.
    case ancestorWantsLayer
    /// What full screen does to the frame view without the transition: full-size content, a transparent
    /// titlebar and the screen's visible frame.
    case windowStyleChange
}

/// The leaf a pane clips: a Chromium page's form (a CALayerHost of another Core Animation context) or a
/// producer's (an IOSurface as layer contents, Ghostty's IOSurfaceLayer).
nonisolated enum SpikeLeaf: String, CaseIterable, Sendable {
    case layerHost
    case ioSurface
}
