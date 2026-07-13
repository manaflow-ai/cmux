#if os(iOS)
import SwiftUI

/// Full-screen native changes flow: tree first, then the selected diff.
struct MobileDiffViewerCover: View {
    let model: MobileDiffViewerModel
    let workspaceTitle: String
    @State private var selectedPath: String?

    var body: some View {
        NavigationStack {
            Group {
                if let selectedPath, let snapshot = model.snapshot {
                    MobileDiffScreen(
                        model: model,
                        snapshot: snapshot,
                        workspaceTitle: workspaceTitle,
                        initialPath: selectedPath,
                        back: { self.selectedPath = nil }
                    )
                } else {
                    MobileDiffTreeScreen(
                        model: model,
                        selectFile: { selectedPath = $0 }
                    )
                }
            }
        }
        .task {
            if model.snapshot == nil {
                await model.load()
            }
        }
        .onDisappear {
            Task { await model.disconnect() }
        }
    }
}
#endif
