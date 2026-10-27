import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import Foundation
import QuartzCore
import CmuxNextWakeups
import Testing
import os

/// Spike p03-rendering-016 (rendering-DESIGN.md R2, "Spike 016"): which layer carries a pane's render-server
/// springs. Two candidates: the pane host's own backing layer (`PaneHostView`), and a dedicated motion container
/// view around the host that only motion code sizes and that keeps the springs it runs. Each test springs a pane
/// with additive springs (mass 1, critically damped, initial velocity 0: the RenderSpring shape), disturbs it,
/// then reads the presented geometry at 25, 50 and 75 % of the way.
///
/// The container's survival is the hypothesis under test: its assertion going red is the result that changes the
/// doc's choice. The backing layer's results are printed as `render-motion-spike` lines for the doc's results
/// table. Each event first proves it did what it names (wrote the springing layer's frame, or replaced the layer),
/// so a case cannot pass because its event did nothing.
///
/// Opt-in (`CMUX_RENDER_SPIKE=1`): the suite opens real windows, enters full screen and runs multi-second springs,
/// so it runs only in the isolated fleet run the doc names, never in a shared `swift test`.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_RENDER_SPIKE"] == "1",
                                        "opt-in fleet spike: set CMUX_RENDER_SPIKE=1"))
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
        let effect = rig.disturb(event, pane: pane)
        switch event.requirement {
        case .nothing:
            break
        case .writesFrame:
            try #require(effect.modelFrameWritten, "\(event) wrote no new frame to the springing layer")
        case .replacesLayer:
            try #require(effect.layerReplaced, "\(event) did not replace the springing view's layer")
        case .mayReplaceLayer:
            // AppKit may keep the layer when the view has a layer-backed ancestor: then the event is no layer
            // replacement, and `layerReassigned` is the case that tests one.
            guard effect.layerReplaced else {
                withKnownIssue("AppKit kept the layer: \(event) does not replace it under a layer-backed ancestor") {
                    Issue.record("\(event): layerReplaced=false, not a replacement case")
                }
                Self.report(layer, event: event.rawValue, errors: nil, effect: effect)
                return
            }
        }
        let errors = try await rig.sample(pane, spring: spring)
        Self.report(layer, event: event.rawValue, errors: errors, effect: effect)
        if layer == .motionContainer {
            #expect(errors.allSatisfy { $0 <= Self.tolerance }, "\(event): off its spring by \(errors) pt at 25/50/75 %")
        }
    }

    /// The window moves to another display mid-spring. Fleet minis have one virtual display, so this runs only on
    /// a host with two; the doc lists the event as not covered until such a run.
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
        Self.report(layer, event: "displayMove", errors: errors, effect: nil)
        if layer == .motionContainer {
            #expect(errors.allSatisfy { $0 <= Self.tolerance }, "display move: off its spring by \(errors) pt")
        }
    }

    /// The window enters full screen mid-spring (a slow spring, so its 25 % mark comes after the transition). The
    /// wait for the transition ends half a second before the 25 % mark, so a late transition is "not entered",
    /// never a missed mark. A `swift test` process has no running NSApplication and may never enter full screen:
    /// that is recorded as not covered (a known issue), and the OS probe `render-motion-survival`, a real app,
    /// covers the event.
    @Test(.enabled("needs a display") { await RenderMotionSpikeTests.hasDisplay() }, arguments: SpikeLayer.allCases)
    func springsSurviveFullScreen(_ layer: SpikeLayer) async throws {
        let rig = try SpikeRig(size: CGSize(width: 900, height: 620))
        defer { rig.close() }
        let pane = rig.addPane(layer, frame: CGRect(x: 40, y: 40, width: 240, height: 180))
        let spring = SpikeSpring(omega: 0.35)
        pane.spring(to: CGRect(x: 240, y: 160, width: 400, height: 280), with: spring)
        let entered = await rig.toggleFullScreen(entering: true, deadline: pane.time(atProgress: 0.25) - 0.5)
        guard entered else {
            if rig.window.styleMask.contains(.fullScreen) {
                _ = await rig.toggleFullScreen(entering: false, deadline: CACurrentMediaTime() + 5)
            }
            withKnownIssue("not covered: the window did not enter full screen before the 25 % mark") {
                Issue.record("full screen not entered in this test process")
            }
            Self.report(layer, event: "fullScreen", errors: nil, effect: nil)
            return
        }
        let sampled: Result<[CGFloat], any Error>
        do {
            sampled = .success(try await rig.sample(pane, spring: spring))
        } catch {
            sampled = .failure(error)
        }
        _ = await rig.toggleFullScreen(entering: false, deadline: CACurrentMediaTime() + 5)
        let errors = try sampled.get()
        Self.report(layer, event: "fullScreen", errors: errors, effect: nil)
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
            let image = try await rig.window.screenshotImage(on: BackgroundWork(label: "test.spike-screenshot"))
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
    /// `CMUX_RENDER_SPIKE_ROUNDS` rounds (3 by default). Each round is a Points of Interest interval (subsystem
    /// com.cmuxterm.render-motion-spike, name `springs`, message the layer), so an xctrace Animation Hitches
    /// recording of the run gives each candidate's render-server hitches
    /// (`scripts/cmux-next/render-motion-spike-hitches.py` counts them). The test itself measures how late each
    /// round's Core Animation completion lands past the spring's settling time.
    @Test(.enabled("needs a display") { await RenderMotionSpikeTests.hasDisplay() }, arguments: SpikeLayer.allCases)
    func twelveMaskedPanesSpring(_ layer: SpikeLayer) async throws {
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
        }
        let sorted = lateLandings.sorted()
        print("render-motion-spike hitch-scenario layer=\(layer.rawValue) late_landing_ms_p50=\(Self.format(sorted[sorted.count / 2])) " +
              "late_landing_ms_max=\(Self.format(sorted.last ?? 0))")
    }

    private static func report(_ layer: SpikeLayer, event: String, errors: [CGFloat]?, effect: SpikeEventEffect?) {
        let marks = errors.map { "p25=\(format($0[0])) p50=\(format($0[1])) p75=\(format($0[2]))" } ?? "notCovered"
        let facts = effect.map { " layerReplaced=\($0.layerReplaced) frameWritten=\($0.modelFrameWritten)" } ?? ""
        print("render-motion-spike layer=\(layer.rawValue) event=\(event) \(marks)\(facts)")
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
    /// The screen view lays the panes out 2 pt away (a new frame on the springing view), the content's frame
    /// changes, the window lays out, and the zero-length animator group a layout sets rest frames through sets
    /// the springing view's frame again.
    case appKitLayout
    /// The pane's superview moves and grows, then the window grows; the superview's layout writes the pane's
    /// scaled frame each time.
    case ancestorSetFrame
    /// The springing view's `wantsLayer` goes off and on.
    case wantsLayer
    /// The superview's `wantsLayer` goes off and on.
    case ancestorWantsLayer
    /// The springing view gets a new backing layer from its `makeBackingLayer()`: a layer replacement for certain.
    case layerReassigned
    /// What full screen does to the frame view without the transition: full-size content, a transparent
    /// titlebar and the screen's visible frame, which the layout writes to the pane.
    case windowStyleChange

    /// What the event must have done for its case to count.
    enum Requirement: Sendable {
        case nothing
        case writesFrame
        case replacesLayer
        case mayReplaceLayer
    }

    var requirement: Requirement {
        switch self {
        case .control: .nothing
        case .appKitLayout, .ancestorSetFrame, .windowStyleChange: .writesFrame
        case .layerReassigned: .replacesLayer
        case .wantsLayer, .ancestorWantsLayer: .mayReplaceLayer
        }
    }
}

/// The leaf a pane clips: a Chromium page's form (a CALayerHost of another Core Animation context) or a
/// producer's (an IOSurface as layer contents, Ghostty's IOSurfaceLayer).
nonisolated enum SpikeLeaf: String, CaseIterable, Sendable {
    case layerHost
    case ioSurface
}
