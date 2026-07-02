#if DEBUG
#if canImport(UIKit)
import CmuxMobileDiagnostics
import GhosttyKit

extension GhosttyRuntime {
    nonisolated static func handleBottomScrollStressDebugAction(
        _ action: ghostty_action_s,
        target: ghostty_target_s
    ) -> Bool {
        guard action.tag == GHOSTTY_ACTION_SCROLLBAR else { return false }
        let sb = action.action.scrollbar
        MobileDebugLog.anchormux("scroll.bar total=\(sb.total) offset=\(sb.offset) len=\(sb.len)")
        if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
            Task { @MainActor in
                GhosttySurfaceView.recordBottomScrollDebugScrollbar(
                    total: Int(sb.total),
                    offset: Int(sb.offset),
                    len: Int(sb.len),
                    for: surface
                )
            }
        }
        return true
    }
}
#endif
#endif
