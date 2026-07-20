#if canImport(UIKit)
import CmuxMobileTerminal
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileShell
@testable import CmuxMobileShellUI

@Suite("Terminal surface mount ownership", .serialized)
struct TerminalSurfaceMountOwnershipTests {
    @MainActor
    @Test("off-window terminal does not claim the output stream")
    func offWindowTerminalDoesNotClaimOutputStream() async throws {
        let store = MobileShellComposite.preview()
        let surfaceID = "off-window-terminal"
        let coordinator = GhosttySurfaceRepresentable.Coordinator(
            workspaceID: "workspace",
            surfaceID: surfaceID,
            store: store,
            artifactFilesEnabled: false,
            terminalFilesChipEnabled: false,
            sessionArtifactCountEnabled: false,
            visibleArtifactCount: 0,
            onArtifactFilesRequested: { _ in },
            onArtifactPathTapped: { _ in },
            onVisibleArtifactCountChanged: { _ in },
            onArtifactGalleryRefreshSignal: { _ in }
        )
        let surfaceView = GhosttySurfaceView(
            runtime: try GhosttyRuntime.shared(),
            delegate: coordinator
        )
        defer {
            coordinator.detach()
            surfaceView.prepareForDismantle()
        }

        #expect(surfaceView.window == nil)
        coordinator.attach(surfaceView: surfaceView)
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(store.terminalByteContinuationsBySurfaceID[surfaceID] == nil)
    }
}
#endif
