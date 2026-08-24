#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileTerminal
import CmuxMobileShellModel
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileShell
@testable import CmuxMobileShellUI

/// The mounted output consumer pumps every terminal chunk on the main actor.
/// Its only shutdown path used to be the SwiftUI `scenePhase` prop arriving
/// through `updateUIView` — which is itself a scene update. Backgrounding a
/// chatty terminal therefore had to win a race against the very main actor the
/// consumer was saturating, and losing it is a `0x8BADF00D` scene-update
/// watchdog kill (observed on TestFlight 1.0.4: `WatchdogEvent: scene-update`,
/// `ProcessVisibility: Background`, faulting frame inside the output loop).
///
/// The consumer must therefore release on the UIApplication lifecycle
/// notifications directly, exactly as the render side already does in
/// `GhosttySurfaceView`, without depending on a scene update running first.
@Suite("Terminal output background suspension", .serialized)
struct TerminalOutputBackgroundSuspensionTests {
    @MainActor
    @Test("backgrounding releases the output consumer without a scene update")
    func backgroundingReleasesOutputConsumerWithoutSceneUpdate() async throws {
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
        let mounted = await waitUntil {
            store.terminalOutputStreamTokensBySurfaceID[surfaceID] != nil
        }
        #expect(mounted)

        // The scene update never runs: no `setTerminalPresentationActive(false)`
        // call, which is what `updateUIView` would deliver. Backgrounding alone
        // has to release the consumer.
        NotificationCenter.default.post(
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        let released = await waitUntil {
            store.terminalOutputStreamTokensBySurfaceID[surfaceID] == nil
        }
        #expect(released)
    }

    @MainActor
    @Test("returning to the foreground remounts the output consumer")
    func returningToForegroundRemountsOutputConsumer() async throws {
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
        #expect(await waitUntil {
            store.terminalOutputStreamTokensBySurfaceID[surfaceID] != nil
        })
        let firstToken = try #require(store.terminalOutputStreamTokensBySurfaceID[surfaceID])

        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        #expect(await waitUntil {
            store.terminalOutputStreamTokensBySurfaceID[surfaceID] == nil
        })

        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
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
        let remounted = await waitUntil {
            guard let token = store.terminalOutputStreamTokensBySurfaceID[surfaceID] else {
                return false
            }
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
