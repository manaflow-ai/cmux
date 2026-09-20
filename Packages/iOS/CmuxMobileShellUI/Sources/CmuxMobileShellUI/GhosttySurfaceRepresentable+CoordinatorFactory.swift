#if canImport(UIKit)
import SwiftUI

extension GhosttySurfaceRepresentable {
    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            store: store,
            terminalPresentationIsActive: terminalPresentationIsActive,
            artifactFilesEnabled: artifactFilesEnabled,
            terminalFolderTapEnabled: terminalFolderTapEnabled,
            terminalFilesChipEnabled: terminalFilesChipEnabled,
            showMissingFiles: showMissingFiles,
            sessionArtifactCountEnabled: sessionArtifactCountEnabled,
            visibleArtifactCount: visibleArtifactCount,
            onArtifactFilesRequested: onArtifactFilesRequested,
            onArtifactPathTapped: onArtifactPathTapped,
            onVisibleArtifactCountChanged: onVisibleArtifactCountChanged,
            onArtifactGalleryRefreshSignal: onArtifactGalleryRefreshSignal
        )
        #if DEBUG
        coordinator.releaseGateUIProbe = releaseGateUIProbe
        #endif
        return coordinator
    }

}
#endif
