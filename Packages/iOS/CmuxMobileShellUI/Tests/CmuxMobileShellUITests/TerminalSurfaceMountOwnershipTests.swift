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

    @MainActor
    @Test("terminal claims output only while attached to a window")
    func terminalClaimsOutputOnlyWhileAttachedToWindow() async throws {
        let store = MobileShellComposite.preview()
        let surfaceID = "window-owned-terminal"
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
        let mounted = await waitUntil {
            store.terminalOutputStreamTokensBySurfaceID[surfaceID] != nil
        }
        #expect(mounted)
        let firstToken = try #require(store.terminalOutputStreamTokensBySurfaceID[surfaceID])

        surfaceView.removeFromSuperview()
        let unmounted = await waitUntil {
            store.terminalOutputStreamTokensBySurfaceID[surfaceID] == nil
        }
        #expect(unmounted)

        host.view.addSubview(surfaceView)
        let remounted = await waitUntil {
            guard let token = store.terminalOutputStreamTokensBySurfaceID[surfaceID] else { return false }
            return token != firstToken
        }
        #expect(remounted)
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
