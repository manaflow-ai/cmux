#if canImport(UIKit)
import CMUXMobileCore
import CmuxAgentReplica
import CmuxMobileTerminal
import CmuxMobileShellModel
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileShell
@testable import CmuxMobileShellUI

@Suite("Terminal surface mount ownership", .serialized)
struct TerminalSurfaceMountOwnershipTests {
    @Test("Agent GUI drafts survive view remounts and remain session scoped")
    func agentGUIDraftsAreHostOwnedAndSessionScoped() {
        let first = AgentSessionID(rawValue: "first")
        let second = AgentSessionID(rawValue: "second")
        var state = AgentGUIDraftState()

        state[first] = "unfinished prompt"
        let remountedState = state

        #expect(remountedState[first] == "unfinished prompt")
        #expect(remountedState[second].isEmpty)
    }

    @MainActor
    @Test("Agent GUI visibility preserves terminal composer and chrome ownership")
    func agentGUIVisibilityPreservesTerminalComposerAndChromeOwnership() async throws {
        let store = MobileShellComposite.preview()
        let workspace = try #require(store.workspaces.first { !$0.terminals.isEmpty })
        let terminal = try #require(workspace.terminals.first)
        let host = UIHostingController(rootView: AgentGUIOwnershipHarness(
            store: store,
            workspaceID: workspace.id.rawValue,
            surfaceID: terminal.id.rawValue,
            isAgentGUIVisible: false
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
        }

        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await settleViewUpdates()

        let surface = try #require(descendant(of: GhosttySurfaceView.self, in: host.view))
        let ownedSubviews = surface.subviews
        #expect(ownedSubviews.count >= 2)

        host.rootView = AgentGUIOwnershipHarness(
            store: store,
            workspaceID: workspace.id.rawValue,
            surfaceID: terminal.id.rawValue,
            isAgentGUIVisible: true
        )
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await settleViewUpdates()

        let hiddenSurface = try #require(descendant(of: GhosttySurfaceView.self, in: host.view))
        #expect(hiddenSurface === surface)
        for ownedSubview in ownedSubviews {
            #expect(hiddenSurface.subviews.contains { $0 === ownedSubview })
            #expect(ownedSubview.superview === hiddenSurface)
        }

        host.rootView = AgentGUIOwnershipHarness(
            store: store,
            workspaceID: workspace.id.rawValue,
            surfaceID: terminal.id.rawValue,
            isAgentGUIVisible: false
        )
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await settleViewUpdates()

        let restoredSurface = try #require(descendant(of: GhosttySurfaceView.self, in: host.view))
        #expect(restoredSurface === surface)
        for ownedSubview in ownedSubviews {
            #expect(restoredSurface.subviews.contains { $0 === ownedSubview })
            #expect(ownedSubview.superview === restoredSurface)
        }
    }

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
    @Test("terminal primes current viewport before claiming output on each mount")
    func terminalPrimesViewportBeforeClaimingOutputOnEachMount() async throws {
        let store = MobileShellComposite.preview()
        let workspace = try #require(store.workspaces.first { !$0.terminals.isEmpty })
        let terminal = try #require(workspace.terminals.first)
        let surfaceID = terminal.id.rawValue
        let coordinator = GhosttySurfaceRepresentable.Coordinator(
            workspaceID: workspace.id.rawValue,
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
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(store.terminalOutputStreamTokensBySurfaceID[surfaceID] == nil)

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
        let firstToken = try #require(store.terminalOutputStreamTokensBySurfaceID[surfaceID])
        #expect(store.viewportReportGenerationsBySurfaceID[surfaceID] == 1)
        #expect(store.reportedViewportSizesByTerminalKey.values.contains(
            MobileTerminalViewportSize(columns: 72, rows: 61)
        ))

        surfaceView.removeFromSuperview()
        let unmounted = await waitUntil {
            store.terminalOutputStreamTokensBySurfaceID[surfaceID] == nil
        }
        #expect(unmounted)

        host.view.addSubview(surfaceView)
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(store.terminalOutputStreamTokensBySurfaceID[surfaceID] == nil)

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

    @MainActor
    private func settleViewUpdates() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    @MainActor
    private func descendant<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = descendant(of: type, in: child) { return match }
        }
        return nil
    }

}

@MainActor
private struct AgentGUIOwnershipHarness: View {
    let store: CMUXMobileShellStore
    let workspaceID: String
    let surfaceID: String
    let isAgentGUIVisible: Bool

    var body: some View {
        WorkspaceDetailSurfaceStack(
            activeSurface: .terminal,
            isAgentGUIVisible: isAgentGUIVisible
        ) {
            GhosttySurfaceRepresentable(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                store: store,
                fontSize: MobileTerminalFontPreference.defaultSize,
                autoFocusOnWindowAttach: false,
                isComposerActive: true,
                terminalTheme: store.activeTerminalTheme,
                terminalConfigTheme: store.activeTerminalConfigTheme,
                configThemeGeneration: store.terminalConfigThemeGeneration
            )
            .id(surfaceID)
        } overlays: {
            if isAgentGUIVisible {
                Color.black
                    .accessibilityIdentifier("AgentGUIOwnershipOverlay")
            }
        }
    }
}
#endif
