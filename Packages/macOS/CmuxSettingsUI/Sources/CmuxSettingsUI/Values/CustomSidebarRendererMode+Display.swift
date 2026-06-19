import CmuxSettings
import Foundation

/// UI-facing labels for ``CustomSidebarRendererMode``, shown by the
/// Custom Sidebars settings section's renderer picker.
extension CustomSidebarRendererMode {
    /// Canonical UI ordering of the modes in the picker.
    static var uiCases: [CustomSidebarRendererMode] {
        [.remote, .inProcess]
    }

    /// Short label shown in the renderer picker.
    var displayName: String {
        switch self {
        case .remote:
            return String(localized: "customSidebarRenderer.remote.name", defaultValue: "Isolated process")
        case .inProcess:
            return String(localized: "customSidebarRenderer.inProcess.name", defaultValue: "In-app (full input)")
        }
    }

    /// One-sentence row subtitle explaining the tradeoff.
    var rendererDescription: String {
        switch self {
        case .remote:
            return String(localized: "customSidebarRenderer.remote.description", defaultValue: "Renders in a crash-isolated helper process. Clicks only: no hover, focus, or typing.")
        case .inProcess:
            return String(localized: "customSidebarRenderer.inProcess.description", defaultValue: "Renders as native SwiftUI inside cmux with hover, focus, and typing. A faulty sidebar shares the app process.")
        }
    }
}
