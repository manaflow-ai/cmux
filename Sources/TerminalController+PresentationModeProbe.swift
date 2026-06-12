#if DEBUG
import AppKit
import QuartzCore

/// In-process attribution for the minimal-mode chrome swap
/// (https://github.com/manaflow-ai/cmux/issues/5732). External samplers cannot
/// attach on macOS 26 (`sample`/`xctrace` fail to read thread state), so the
/// `set_presentation_mode` probe resets these counters before flipping the mode
/// and logs them once the main thread turns the run loop again. Body counts
/// tell us which subtrees SwiftUI actually re-evaluated during the swap.
@MainActor
enum PresentationModeToggleDiagnostics {
    static var contentViewBodyCount = 0
    static var sidebarBodyCount = 0
    static var workspaceContentBodyCount = 0
    static var safeAreaBridgeBodyCount = 0
    static var chromeHostBodyCount = 0
    static var tabItemBodyCount = 0

    static func reset() {
        contentViewBodyCount = 0
        sidebarBodyCount = 0
        workspaceContentBodyCount = 0
        safeAreaBridgeBodyCount = 0
        chromeHostBodyCount = 0
        tabItemBodyCount = 0
    }

    static func summary() -> String {
        "contentView=\(contentViewBodyCount) sidebar=\(sidebarBodyCount) " +
        "workspaceContent=\(workspaceContentBodyCount) bridge=\(safeAreaBridgeBodyCount) " +
        "chromeHost=\(chromeHostBodyCount) tabItem=\(tabItemBodyCount)"
    }
}

extension TerminalController {
    /// Test-only socket verb (`set_presentation_mode <minimal|standard|toggle>`).
    /// Drives the same UserDefaults mutation as the palette commands and the
    /// Settings toggle, then logs how long the main thread stays busy before it
    /// can turn the run loop again — i.e. the synchronous SwiftUI/AttributeGraph
    /// relayout cost of the chrome swap (https://github.com/manaflow-ai/cmux/issues/5732).
    /// `setMs` isolates the synchronous `UserDefaults.set` observer work
    /// (defaults-didChange listeners, decoration reapply) from the SwiftUI/CA
    /// commit that follows; the body counters attribute the commit.
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
            PresentationModeToggleDiagnostics.reset()
            let t0 = CACurrentMediaTime()
            UserDefaults.standard.set(next.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
            let setMs = (CACurrentMediaTime() - t0) * 1000
            DispatchQueue.main.async {
                let dtMs = (CACurrentMediaTime() - t0) * 1000
                cmuxDebugLog(
                    "presentationMode.set mode=\(next.rawValue) " +
                    "mainBlockedMs=\(String(format: "%.1f", dtMs)) " +
                    "setMs=\(String(format: "%.1f", setMs)) " +
                    "bodies{\(PresentationModeToggleDiagnostics.summary())}"
                )
            }
            result = "OK \(current.rawValue) -> \(next.rawValue)"
        }
        return result
    }
}
#endif
