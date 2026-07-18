import CmuxTerminalFrontend
import Testing

@Suite struct TerminalFrontendDomainExportTests {
    @Test func frontendReexportsTheCompletePersistentRuntimeContract() {
        let exportedValueTypes: [Any.Type] = [
            TerminalExternalPresentation.self,
            TerminalExternalRuntimeLifecycle.self,
            TerminalExternalProcessMetadata.self,
            TerminalAccessibilityRange.self,
            TerminalAccessibilityCell.self,
            TerminalAccessibilityLine.self,
            TerminalAccessibilityCursor.self,
            TerminalAccessibilitySelection.self,
            TerminalAccessibilityLink.self,
            TerminalAccessibilitySnapshot.self,
            TerminalExternalCellMetrics.self,
            TerminalExternalRuntimeSnapshot.self,
            TerminalExternalCellPoint.self,
            TerminalExternalCursorState.self,
            TerminalExternalSelection.self,
            TerminalExternalSearchState.self,
            TerminalExternalViewportState.self,
            TerminalExternalTextKind.self,
            TerminalExternalTextInput.self,
            TerminalExternalKeyModifiers.self,
            TerminalExternalKeyAction.self,
            TerminalExternalKeyEvent.self,
            TerminalExternalInput.self,
            TerminalExternalViewport.self,
            TerminalExternalMouseAction.self,
            TerminalExternalMouseButton.self,
            TerminalExternalMouseEvent.self,
            TerminalExternalHyperlinkHit.self,
            TerminalExternalPreedit.self,
            TerminalExternalRuntimeMutation.self,
            TerminalExternalSelectionOperation.self,
            TerminalExternalCopyModeOperation.self,
            TerminalExternalCopyModeAdjustment.self,
            TerminalExternalSearchOperation.self,
            TerminalExternalScrollOperation.self,
            TerminalExternalIngressRejection.self,
            TerminalExternalIngressResult.self,
            TerminalExternalScreenTextRequest.self,
        ]

        #expect(exportedValueTypes.count == 38)
    }

    private func acceptsExportedProtocols(
        _ lease: any TerminalExternalPresentationLease,
        runtime: any TerminalExternalRuntime
    ) {
        _ = lease
        _ = runtime
    }
}
