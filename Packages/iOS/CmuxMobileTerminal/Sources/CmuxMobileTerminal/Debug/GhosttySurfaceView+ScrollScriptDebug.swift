#if DEBUG
#if canImport(UIKit)
import CmuxMobileDiagnostics
import Foundation
import UIKit

extension GhosttySurfaceView {
    /// Read once so the disabled per-frame cost is a single boolean check.
    private static let debugScrollScriptEnabled =
        ProcessInfo.processInfo.environment["CMUX_UITEST_SCROLL_SCRIPT"] == "1"

    /// One-shot scripted scroll phases: (name, frame count, per-frame deltaY;
    /// nil = idle hold). Drives the real gesture accumulation path so headless
    /// simulator runs verify pixel scrolling without GUI taps.
    private static let debugScrollScriptPhases: [(name: String, frames: Int, deltaY: CGFloat?)] = [
        ("wait", 900, nil),
        ("slow", 300, -2.0),
        ("hold", 180, nil),
        ("fast", 90, -12.0),
        ("hold2", 180, nil),
        ("down", 240, 6.0),
    ]

    /// Steps the scroll script one display-link frame. One-shot: after the
    /// final bottom snap the latch stays set and the script never repeats.
    func debugStepScrollScriptIfNeeded() {
        guard Self.debugScrollScriptEnabled,
              !debugScrollScriptDone,
              window != nil,
              surface != nil else { return }
        let frame = debugScrollScriptFrame
        debugScrollScriptFrame += 1
        var phaseStart = 0
        for phase in Self.debugScrollScriptPhases {
            if frame < phaseStart + phase.frames {
                if frame == phaseStart {
                    MobileDebugLog.anchormux("scroll_script phase=\(phase.name) frame=\(frame)")
                }
                if let deltaY = phase.deltaY {
                    enqueueScrollMechanicsDelta(
                        deltaY,
                        touchPoint: CGPoint(x: bounds.midX, y: bounds.midY)
                    )
                }
                return
            }
            phaseStart += phase.frames
        }
        MobileDebugLog.anchormux("scroll_script phase=bottom frame=\(frame)")
        enqueueScrollToBottom()
        debugScrollScriptDone = true
    }

    /// Scroll-smoothness audit: logs the display's max rate once, then one
    /// per-second summary of achieved display-link cadence while a scroll
    /// gesture or its deceleration is active. `scroll_fps` is what the app
    /// achieved, `link_fps` is the rate Core Animation currently grants, and
    /// `missed` counts ticks that arrived over 1.6x the granted frame time.
    func debugRecordScrollFrameRateTick(now: CFTimeInterval) {
        if !debugScrollFrameRateStats.loggedDisplayInfo,
           let screen = window?.windowScene?.screen {
            debugScrollFrameRateStats.loggedDisplayInfo = true
            MobileDebugLog.anchormux(
                "perf.display max_fps=\(screen.maximumFramesPerSecond)"
            )
        }
        guard scrollInteractionActive else {
            debugScrollFrameRateStats.windowStart = 0
            debugScrollFrameRateStats.ticks = 0
            debugScrollFrameRateStats.missed = 0
            debugScrollFrameRateStats.maxGapMs = 0
            return
        }
        if debugScrollFrameRateStats.windowStart == 0 {
            debugScrollFrameRateStats.windowStart = now
            debugScrollFrameRateStats.lastTick = now
            return
        }
        let gap = now - debugScrollFrameRateStats.lastTick
        debugScrollFrameRateStats.lastTick = now
        debugScrollFrameRateStats.ticks += 1
        debugScrollFrameRateStats.maxGapMs = max(
            debugScrollFrameRateStats.maxGapMs,
            gap * 1000
        )
        let grantedDuration = displayLink?.duration ?? 0
        if grantedDuration > 0, gap > grantedDuration * 1.6 {
            debugScrollFrameRateStats.missed += 1
        }
        let windowElapsed = now - debugScrollFrameRateStats.windowStart
        guard windowElapsed >= 1.0 else { return }
        let fps = Double(debugScrollFrameRateStats.ticks) / windowElapsed
        let linkFps = grantedDuration > 0 ? Int((1.0 / grantedDuration).rounded()) : 0
        MobileDebugLog.anchormux(
            "perf.refresh scroll_fps=\(Int(fps.rounded())) link_fps=\(linkFps) missed=\(debugScrollFrameRateStats.missed) max_gap_ms=\(Int(debugScrollFrameRateStats.maxGapMs))"
        )
        debugScrollFrameRateStats.windowStart = now
        debugScrollFrameRateStats.ticks = 0
        debugScrollFrameRateStats.missed = 0
        debugScrollFrameRateStats.maxGapMs = 0
    }
}
#endif
#endif
