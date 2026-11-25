#if os(iOS)
import Observation
import QuartzCore
import UIKit

/// Runs `TabZoomState` on the display's frame clock. Views read `state`
/// (progress drives every frame of the zoom); actions mutate it through the
/// methods below, which retarget the running spring instead of queueing.
@MainActor
@Observable
final class TabZoomDriver {
    private(set) var state = TabZoomState(motion: TabZoomDriver.variant)
    /// The transition's taste (`-tabs-transition NAME`), read once per launch.
    nonisolated static let variant = TabTransitionVariant.fromEnvironment()
    /// The cards' close buttons and titles (their own clock after 0.96).
    private(set) var chrome = CardChrome()
    @ObservationIgnored var onSettle: ((TabZoomState.Phase) -> Void)?
    /// The zoom just turned toward the page (a tap, a reversal, a pinch
    /// released that way). Called in the same update as the change, before
    /// the page's content is held for the flight, so what the page lands
    /// with (its toolbar insets) is set before it moves, not after it lands.
    @ObservationIgnored var onHeadingToPage: (() -> Void)?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    @ObservationIgnored private lazy var proxy = DisplayLinkProxy { [weak self] link in self?.tick(link) }

    func go(toOverview: Bool) { mutate { $0.go(toOverview: toOverview) } }
    func openNewTab(spring: ZoomSpring = .newTab) { mutate { $0.openNewTab(spring: spring) } }
    func beginInteraction() { mutate { $0.beginInteraction() } }
    func updateInteraction(progress: Double, velocity: Double) { mutate { $0.updateInteraction(progress: progress, velocity: velocity) } }
    func updateInteraction(progress: Double, offset: CGVector, velocity: Double, offsetVelocity: CGVector) {
        mutate { $0.updateInteraction(progress: progress, offset: offset, velocity: velocity, offsetVelocity: offsetVelocity) }
    }
    func release(toOverview: Bool) { mutate { $0.release(toOverview: toOverview) } }
    @discardableResult
    func endInteraction(velocity: Double, startedFromOverview: Bool) -> Bool {
        var toOverview = false
        mutate { toOverview = $0.endInteraction(velocity: velocity, startedFromOverview: startedFromOverview) }
        return toOverview
    }
    func jump(toOverview: Bool) { mutate { $0.jump(toOverview: toOverview) } }

    /// The first display frame after a curve starts from rest holds still:
    /// that frame renders the change that started it (the grid, the zoom
    /// rect, a newly selected tab's page), which took 25-60 ms in the
    /// simulator. Stepping the curve in it as well left the next frame
    /// 40-60 ms late, a visible stall in the zoom's first frames.
    @ObservationIgnored private var buildFrame = false

    #if DEBUG
    /// Frame times of each tap-started zoom (`CMUX_TABS_FRAME_LOG=1`): one
    /// JSON line per settled zoom in `Documents/tabs-zoom-frames.jsonl` and
    /// on stdout (`TABZOOM_FRAMES`), read by TabZoomFrameTimeUITests.
    @ObservationIgnored private var frameLog = ZoomFrameLog()
    private static let logsFrames = ProcessInfo.processInfo.environment["CMUX_TABS_FRAME_LOG"] == "1"
    #endif

    private func mutate(_ change: (inout TabZoomState) -> Void) {
        let before = state.phase
        let curveBefore = state.curve
        let targetBefore = state.target
        change(&state)
        if state.target == 0, targetBefore == 1, state.phase == .animating { onHeadingToPage?() }
        if state.phase == .animating, state.curve != nil, curveBefore == nil, before == .page || before == .overview {
            buildFrame = true
        }
        if UIAccessibility.isReduceMotionEnabled, state.phase == .animating {
            state.jump(toOverview: state.target == 1)
        }
        #if DEBUG
        if Self.logsFrames {
            if state.phase == .animating, before == .page || before == .overview {
                frameLog.begin(at: CACurrentMediaTime(), toOverview: state.target == 1)
                AccessoryProbe.trace.reset()
            } else if state.phase != .animating, frameLog.isRunning {
                // A pinch grabbed it or it jumped: not a tap-to-settled zoom.
                _ = frameLog.end(maxFPS: 0)
            }
        }
        #endif
        stepChrome(0)
        if UIAccessibility.isReduceMotionEnabled, state.phase != .animating {
            chrome.settle(onOverview: state.phase == .overview)
        }
        if state.phase == .animating || chrome.animating {
            startLink()
        } else {
            stopLink()
        }
        if state.phase != .animating, before != state.phase, state.phase == .page || state.phase == .overview { onSettle?(state.phase) }
    }

    private func stepChrome(_ dt: Double) {
        var c = chrome
        c.step(dt, progress: state.progress, headingToOverview: state.phase == .interactive || (state.headingToOverview && state.phase != .page),
               settledOnOverview: state.phase == .overview)
        if c != chrome { chrome = c }
    }

    private func startLink() {
        guard link == nil else { return }
        let l = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.fire(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        lastTimestamp = nil
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
    }

    private func tick(_ link: CADisplayLink) {
        // Step to the time this frame will be shown (targetTimestamp) so the
        // first frame after a tap already moves.
        let now = link.targetTimestamp
        let dt = lastTimestamp.map { now - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastTimestamp = now
        #if DEBUG
        if frameLog.isRunning { frameLog.frame(at: now) }
        #endif
        let wasAnimating = state.phase == .animating
        if buildFrame {
            buildFrame = false
            if wasAnimating { return }
        }
        let settled = wasAnimating && state.step(dt)
        stepChrome(dt)
        if wasAnimating, settled || state.phase != .animating {
            #if DEBUG
            if var summary = frameLog.end(maxFPS: Int((1 / max(0.001, link.targetTimestamp - link.timestamp)).rounded())) {
                summary.row = AccessoryProbe.trace.summary(toOverview: summary.toOverview)
                Self.write(summary)
            }
            #endif
            onSettle?(state.phase)
        }
        if state.phase != .animating, !chrome.animating { stopLink() }
    }
}

#if DEBUG
/// The accessory row's samples for the running zoom's frame log: TabsView
/// notes what it draws while the zoom moves (`CMUX_TABS_FRAME_LOG=1` only).
@MainActor
enum AccessoryProbe {
    static var trace = AccessoryTrace()
    static let on = ProcessInfo.processInfo.environment["CMUX_TABS_FRAME_LOG"] == "1"

    /// `bottom`: the row's bottom edge in the full-screen layer, before the zoom's mapping.
    static func note(_ z: AccessoryZoom, moving: Bool, bottom: CGFloat? = nil) {
        guard on, moving else { return }
        trace.note(opacity: z.opacity, scale: Double(z.scale), bottom: bottom.map { Double(z.origin.y + z.scale * $0) })
    }
}

extension TabZoomDriver {
    fileprivate static func write(_ summary: ZoomFrameLog.Summary) {
        guard let data = try? JSONEncoder().encode(summary), let line = String(data: data, encoding: .utf8) else { return }
        print("TABZOOM_FRAMES \(line)")
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("tabs-zoom-frames.jsonl")
        let row = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: row)
            try? handle.close()
        } else {
            try? row.write(to: url)
        }
    }
}
#endif

/// CADisplayLink retains its target; this breaks the cycle.
@MainActor
private final class DisplayLinkProxy: NSObject {
    let handler: @MainActor (CADisplayLink) -> Void
    init(_ handler: @escaping @MainActor (CADisplayLink) -> Void) { self.handler = handler }
    @objc func fire(_ link: CADisplayLink) { handler(link) }
}
#endif
