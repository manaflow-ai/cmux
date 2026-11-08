import SwiftUI

struct WorkspaceTitlebarModeLayer<Titlebar: View>: View {
    let titlebar: () -> Titlebar

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var body: some View {
        if !isMinimalMode {
            titlebar()
        }
    }
}
