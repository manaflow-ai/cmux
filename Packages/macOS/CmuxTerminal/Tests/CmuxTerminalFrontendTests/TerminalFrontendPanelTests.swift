import AppKit
import CmuxTerminalFrontend
import Foundation
import Testing

@MainActor
@Suite struct TerminalFrontendPanelTests {
    @Test func facadeForwardsCanonicalRuntimeWithoutTerminalOwnership() async throws {
        let surfaceID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let workspaceID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let replacementWorkspaceID = UUID(
            uuidString: "30000000-0000-0000-0000-000000000003"
        )!
        let runtime = FakeTerminalExternalRuntime()
        let surfaceView = TerminalFrontendSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let panel = TerminalFrontendPanel(
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            runtime: runtime,
            surfaceView: surfaceView
        )

        let lease = panel.attachPresentation(
            TerminalExternalPresentation(
                surfaceID: surfaceID,
                workspaceID: workspaceID
            ))
        panel.adoptCanonicalPlacement(workspaceID: replacementWorkspaceID)
        let ingress = panel.enqueue(.focus(true))
        panel.enableAccessibility()

        #expect(lease === runtime.lease)
        #expect(panel.surfaceView === surfaceView)
        #expect(panel.snapshot.visibleText == "backend-owned")
        #expect(panel.workspaceID == replacementWorkspaceID)
        #expect(
            runtime.presentations == [
                TerminalExternalPresentation(
                    surfaceID: surfaceID,
                    workspaceID: workspaceID
                )
            ])
        #expect(runtime.adoptedWorkspaceIDs == [replacementWorkspaceID])
        #expect(runtime.mutations == [.focus(true)])
        #expect(ingress == .accepted(sequence: 1))
        #expect(runtime.accessibilityEnableCount == 1)
        #expect(await panel.readScreenText(.visible) == "visible text")
        #expect(await panel.readSelection()?.text == "selected")
    }

    @Test func facadeForwardsLinkActivationWithExactCoordinates() async throws {
        let surfaceID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let runtime = FakeTerminalExternalRuntime()
        let panel = TerminalFrontendPanel(
            surfaceID: surfaceID,
            workspaceID: UUID(),
            runtime: runtime
        )
        let event = TerminalExternalMouseEvent(
            action: .press,
            button: .left,
            modifiers: [],
            xPixels: 7,
            yPixels: 11,
            anyButtonPressed: true
        )

        let hit = await panel.activateHyperlink(at: event)

        #expect(hit?.target == "https://example.com")
        #expect(hit?.column == 7)
        #expect(hit?.row == 11)
    }
}
