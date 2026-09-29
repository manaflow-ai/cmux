import SwiftUI

struct WorkspacePresentationModeChangeObserver: View {
    let onChange: (Bool, Bool) -> Void

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    @AppStorage(WorkspaceTitlebarSettings.showTitlebarKey)
    private var showWorkspaceTitlebar = WorkspaceTitlebarSettings.defaultShowTitlebar

    private var hasHiddenTitlebar: Bool {
        WorkspaceTitlebarSettings.isHidden(
            showTitlebar: showWorkspaceTitlebar,
            presentationMode: workspacePresentationMode
        )
    }

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear {
                onChange(isMinimalMode, hasHiddenTitlebar)
            }
            .onChange(of: showWorkspaceTitlebar) { _, _ in
                onChange(isMinimalMode, hasHiddenTitlebar)
            }
            .onChange(of: isMinimalMode) { _, newValue in
                onChange(newValue, hasHiddenTitlebar)
            }
    }
}
