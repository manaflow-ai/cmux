#if DEBUG
import AppKit
import QuartzCore

extension TerminalController {
    /// Test-only socket verb (`set_presentation_mode <minimal|standard|toggle>`).
    /// Drives the same UserDefaults mutation as the palette commands and the
    /// Settings toggle, then logs how long the main thread stays busy before it
    /// can turn the run loop again — i.e. the synchronous SwiftUI/AttributeGraph
    /// relayout cost of the chrome swap (https://github.com/manaflow-ai/cmux/issues/5732).
    /// `setMs` isolates the synchronous `UserDefaults.set` observer work
    /// (defaults-didChange listeners, decoration reapply) from the SwiftUI/CA
    /// commit that follows.
    func setPresentationModeForTesting(_ args: String) -> String {
        let argument = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = "ERROR: Usage: set_presentation_mode <minimal|standard|toggle>"
        v2MainSync {
            let current = WorkspacePresentationModeSettings.mode()
            let next: WorkspacePresentationModeSettings.Mode?
            switch argument {
            case "minimal": next = .minimal
            case "standard": next = .standard
            case "toggle": next = current == .minimal ? .standard : .minimal
            default: next = nil
            }
            guard let next else { return }
            let t0 = CACurrentMediaTime()
            UserDefaults.standard.set(next.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
            let setMs = (CACurrentMediaTime() - t0) * 1000
            // Deliberately deferred (not awaited): the job runs on the next
            // main-actor drain, i.e. after the current run-loop turn finishes
            // the SwiftUI/CA commit, so the delta measures the full
            // synchronous main-thread block caused by the toggle.
            Task { @MainActor in
                let dtMs = (CACurrentMediaTime() - t0) * 1000
                cmuxDebugLog(
                    "presentationMode.set mode=\(next.rawValue) " +
                    "mainBlockedMs=\(String(format: "%.1f", dtMs)) " +
                    "setMs=\(String(format: "%.1f", setMs))"
                )
            }
            result = "OK \(current.rawValue) -> \(next.rawValue)"
        }
        return result
    }
}
#endif
