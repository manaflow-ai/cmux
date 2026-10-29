import AppKit
import Combine

/// A workspace pane that keeps the CodeRouter guide available beside the user's work.
@MainActor
final class CoderouterGuidePanel: Panel {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .coderouterGuide

    var displayTitle: String {
        String(localized: "coderouter.guide.title", defaultValue: "coderouter")
    }

    var displayIcon: String? { "questionmark.circle" }

    init(id: UUID = UUID()) {
        self.id = id
    }

    func close() {}
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
