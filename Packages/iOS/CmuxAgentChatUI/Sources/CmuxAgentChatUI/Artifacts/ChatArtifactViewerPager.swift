import CmuxAgentChat
import SwiftUI

/// Keeps only the selected artifact and its adjacent viewer pages mounted.
struct ChatArtifactViewerPager: View {
    let initialPath: String
    let scope: ChatArtifactViewerScope
    let swipeOrder: ChatArtifactGallerySwipeOrder
    let onDone: () -> Void

    @State private var selectedPath: String
    @State private var zoomedPath: String?

    init(
        initialPath: String,
        scope: ChatArtifactViewerScope,
        swipeOrder: ChatArtifactGallerySwipeOrder,
        onDone: @escaping () -> Void
    ) {
        self.initialPath = initialPath
        self.scope = scope
        self.swipeOrder = swipeOrder
        self.onDone = onDone
        _selectedPath = State(initialValue: initialPath)
    }

    @ViewBuilder
    var body: some View {
        #if os(iOS)
        if swipeOrder.count > 1,
           swipeOrder.files.contains(where: { $0.path == initialPath }) {
            TabView(selection: $selectedPath) {
                ForEach(swipeOrder.pageWindow(around: selectedPath)) { file in
                    viewer(path: file.path)
                        .tag(file.path)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .scrollDisabled(zoomedPath != nil)
        } else {
            viewer(path: initialPath)
        }
        #else
        viewer(path: initialPath)
        #endif
    }

    private func viewer(path: String) -> some View {
        NavigationStack {
            ChatArtifactViewerRouteView(
                path: path,
                scope: scope,
                onImageMinimumZoomChanged: { isAtMinimum in
                    if isAtMinimum {
                        if zoomedPath == path {
                            zoomedPath = nil
                        }
                    } else {
                        zoomedPath = path
                    }
                },
                onDone: onDone
            )
        }
    }
}
