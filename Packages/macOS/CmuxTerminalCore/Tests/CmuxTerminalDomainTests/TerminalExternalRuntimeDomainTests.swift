import CmuxTerminalDomain
import Foundation
import Testing

@Suite struct TerminalExternalRuntimeDomainTests {
    @Test func persistentRuntimeValuesRemainGhosttyFreeAndCoherent() {
        let presentation = TerminalExternalPresentation(
            surfaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let viewport = TerminalExternalViewport(
            widthPoints: 800,
            heightPoints: 600,
            widthPixels: 1600,
            heightPixels: 1200,
            xScale: 2,
            yScale: 2,
            proposedColumns: 100,
            proposedRows: 40
        )
        let preedit = TerminalExternalPreedit.collapsedAtEnd("a😀")
        let mutation = TerminalExternalRuntimeMutation.resize(viewport)
        let snapshot = TerminalExternalRuntimeSnapshot(
            lifecycle: .live,
            visibleText: "prompt",
            viewportState: TerminalExternalViewportState(
                totalRows: 400,
                offset: 20,
                visibleRows: 40
            )
        )

        #expect(presentation.surfaceID.uuidString.hasSuffix("0001"))
        #expect(preedit.caretUTF16 == 3)
        #expect(mutation == .resize(viewport))
        #expect(snapshot.lifecycle == .live)
        #expect(snapshot.viewportState?.visibleRows == 40)
        #expect(TerminalExternalIngressResult.accepted(sequence: 7).accepted)
        #expect(!TerminalExternalIngressResult.rejected(.queueFull).accepted)
    }
}
