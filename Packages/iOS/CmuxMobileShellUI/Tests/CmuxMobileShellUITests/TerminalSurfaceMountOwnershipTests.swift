#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileTerminal
import CmuxMobileShellModel
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
            terminalFolderTapEnabled: false,
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

    @MainActor
    @Test("terminal claims output without waiting for a resize on each mount")
    func terminalClaimsOutputWithoutWaitingForResizeOnEachMount() async throws {
        let store = MobileShellComposite.preview()
        let workspace = try #require(store.workspaces.first { !$0.terminals.isEmpty })
        let terminal = try #require(workspace.terminals.first)
        let surfaceID = terminal.id.rawValue
        let coordinator = GhosttySurfaceRepresentable.Coordinator(
            workspaceID: workspace.id.rawValue,
            surfaceID: surfaceID,
            store: store,
            artifactFilesEnabled: false,
            terminalFolderTapEnabled: false,
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
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        coordinator.attach(surfaceView: surfaceView)
        defer {
            surfaceView.removeFromSuperview()
            coordinator.detach()
            surfaceView.prepareForDismantle()
            window.isHidden = true
        }

        surfaceView.frame = host.view.bounds
        host.view.addSubview(surfaceView)
        let mountedWithoutResize = await waitUntil {
            store.terminalOutputStreamTokensBySurfaceID[surfaceID] != nil
        }
        #expect(mountedWithoutResize)
        let firstToken = try #require(store.terminalOutputStreamTokensBySurfaceID[surfaceID])
        #expect(store.terminalViewportGeneration(for: surfaceID) == 0)

        coordinator.ghosttySurfaceView(
            surfaceView,
            didResize: TerminalGridSize(
                columns: 72,
                rows: 61,
                pixelWidth: 1_296,
                pixelHeight: 2_135
            ),
            reportID: 1
        )
        #expect(store.terminalViewportGeneration(for: surfaceID) == 1)
        #expect(store.reportedViewportSizesByTerminalKey.values.contains(
            MobileTerminalViewportSize(columns: 72, rows: 61)
        ))

        surfaceView.removeFromSuperview()
        let unmounted = await waitUntil {
            store.terminalOutputStreamTokensBySurfaceID[surfaceID] == nil
        }
        #expect(unmounted)

        host.view.addSubview(surfaceView)
        let remountedWithoutResize = await waitUntil {
            guard let token = store.terminalOutputStreamTokensBySurfaceID[surfaceID] else { return false }
            return token != firstToken
        }
        #expect(remountedWithoutResize)

        coordinator.ghosttySurfaceView(
            surfaceView,
            didResize: TerminalGridSize(
                columns: 72,
                rows: 61,
                pixelWidth: 1_296,
                pixelHeight: 2_135
            ),
            reportID: 2
        )
        #expect(store.terminalViewportGeneration(for: surfaceID) == 2)
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 100,
        _ predicate: () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}
#endif
