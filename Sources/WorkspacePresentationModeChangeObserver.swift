import SwiftUI

struct WorkspacePresentationModeChangeObserver: View {
    let onChange: (Bool) -> Void

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear {
                onChange(isMinimalMode)
            }
            .onChange(of: isMinimalMode) { _, newValue in
                onChange(newValue)
            }
    }
}
