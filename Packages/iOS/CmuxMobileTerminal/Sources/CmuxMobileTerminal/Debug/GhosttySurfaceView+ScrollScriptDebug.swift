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
}
#endif
#endif
