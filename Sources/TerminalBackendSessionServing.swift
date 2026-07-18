import CmuxTerminalBackend
import Foundation

/// Test seam over one exact credential-fenced canonical daemon connection.
protocol TerminalBackendSessionServing: Sendable {
    func backendCompatibility() async throws -> BackendCompatibilityResult
    func events() async -> AsyncStream<BackendCanonicalSessionEvent>
    func connect() async throws -> TopologySnapshot?
    func close() async
    func currentTerminalActivitySnapshot() async -> BackendTerminalActivitySnapshot?
    func makeTopologyMutationExpectation(
        requestID: UUID,
        authority: BackendAuthority,
        revision: UInt64
    ) async throws -> BackendTopologyMutationExpectation
    func markTerminalSeen(
        surfaceID: SurfaceID,
        activitySequence: UInt64
    ) async throws -> BackendTerminalActivityReceipt

    func ensureTerminal(
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        workingDirectory: String?,
        command: String?,
        arguments: [String]?,
        environment: [String: String],
        initialInput: String?,
        waitAfterCommand: Bool,
        columns: UInt16,
        rows: UInt16
    ) async throws -> BackendEnsuredTerminalPlacement
    func ensureTerminals(
        _ requests: [BackendEnsureTerminalRequest]
    ) async throws -> [BackendEnsuredTerminalPlacement]
    func reparentTerminal(
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID
    ) async throws -> BackendReparentedTerminalPlacement

    func newWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        name: String?,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement
    func newTerminalTab(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement
    func newBrowserWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        name: String?,
        url: URL,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement
    func newBrowserTab(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        url: URL,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement
    func splitBrowserPane(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        direction: BackendSplitDirection,
        initialRatio: Float,
        url: URL,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement
    func materializeTerminal(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement
    func respawnTerminal(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement
    func splitPane(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        direction: BackendSplitDirection,
        initialRatio: Float,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement
    func splitTab(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        paneID: PaneID,
        direction: BackendSplitDirection,
        initialRatio: Float
    ) async throws -> BackendSurfacePlacement
    func closePane(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID
    ) async throws -> BackendTopologyMutationReceipt
    func closeWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID
    ) async throws -> BackendTopologyMutationReceipt
    func renameWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        name: String
    ) async throws -> BackendTopologyMutationReceipt
    func renameSurface(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        name: String
    ) async throws -> BackendTopologyMutationReceipt
    func moveTab(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        paneID: PaneID,
        index: UInt64
    ) async throws -> BackendTopologyMutationReceipt
    func reorderTabs(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceIDs: [SurfaceID]
    ) async throws -> BackendTopologyMutationReceipt
    func reorderWorkspaces(
        expectation: BackendTopologyMutationExpectation,
        workspaceIDs: [WorkspaceID]
    ) async throws -> BackendTopologyMutationReceipt
    func moveTabToNewWorkspace(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID,
        name: String?,
        index: UInt64?
    ) async throws -> BackendSurfacePlacement
    func setSplitRatio(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        direction: BackendSplitDirection,
        ratio: Float
    ) async throws -> BackendTopologyMutationReceipt

    func openPresentation(
        view: BackendPresentationView,
        zoom: BackendPresentationZoom,
        scroll: BackendPresentationScroll
    ) async throws -> BackendPresentation
    func closePresentation(id: PresentationID) async throws
    func configureRendererPresentation(
        id: PresentationID,
        expectedGeneration: UInt64,
        configuration: BackendRendererPresentationConfiguration
    ) async throws -> BackendRendererPresentationReceipt
    func detachRendererPresentation(
        id: PresentationID,
        expectedGeneration: UInt64
    ) async throws
    func setTerminalPreedit(
        presentationID: PresentationID,
        rendererGeneration: UInt64,
        text: String?
    ) async throws
    func setTerminalPreedit(
        presentationID: PresentationID,
        rendererGeneration: UInt64,
        preedit: BackendTerminalPreedit?
    ) async throws
    func releaseRendererFrame(
        _ release: BackendRendererFrameRelease
    ) async throws -> BackendRendererFrameReleaseResponse
    func rendererWorkers() async throws -> BackendRendererWorkersResponse
    func claimProjectionState(
        logicalPresentationID: UUID
    ) async throws -> BackendProjectionState
    func updateProjectionState(
        logicalPresentationID: UUID,
        claimID: UUID,
        expectedGeneration: UInt64,
        workspaces: [BackendProjectionWorkspaceState]
    ) async throws -> BackendProjectionState
    func updateProjectionStates(
        _ projections: [BackendProjectionStateUpdate]
    ) async throws -> [BackendProjectionState]
    func releaseProjectionState(
        logicalPresentationID: UUID,
        claimID: UUID,
        expectedGeneration: UInt64
    ) async throws
    func listProjectionStates() async throws -> [BackendProjectionState]

    func terminalControlProtocol() async throws -> BackendTerminalControlProtocol
    func acquireTerminalControl(
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        ttlMilliseconds: UInt64
    ) async throws -> BackendTerminalControlLease
    func acquireTerminalLease(
        kind: BackendTerminalLeaseKind,
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        ttlMilliseconds: UInt64
    ) async throws -> BackendTerminalLease
    func releaseTerminalLease(
        kind: BackendTerminalLeaseKind,
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64
    ) async throws
    func releaseTerminalControl(
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64
    ) async throws
    func sendTerminalInput(
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        requestID: UUID,
        input: BackendTerminalControlInput
    ) async throws -> BackendTerminalOperationReceipt
    func sendTerminalGeometry(
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        requestID: UUID,
        columns: UInt16,
        rows: UInt16
    ) async throws -> BackendTerminalOperationReceipt
    func terminalRequestStatus(
        surfaceID: SurfaceID,
        requestID: UUID
    ) async throws -> BackendTerminalOperationReceipt
    func acknowledgeTerminalRequest(
        surfaceID: SurfaceID,
        requestID: UUID
    ) async throws -> Bool

    func sendTerminalKey(
        surface: UInt64,
        event: BackendTerminalKeyEvent
    ) async throws -> BackendTerminalKeyResponse
    func sendTerminalNamedKey(surface: UInt64, key: String) async throws
    func sendTerminalMouse(
        surface: UInt64,
        event: BackendTerminalMouseEvent
    ) async throws -> BackendTerminalMouseResponse
    func sendTerminalText(surface: UInt64, text: String, paste: Bool) async throws
    func terminalState(surfaceID: SurfaceID) async throws -> BackendTerminalStateResponse
    func terminalAccessibilitySnapshot(
        presentationID: PresentationID,
        expectedGeneration: UInt64,
        expectedContentSequence: UInt64
    ) async throws -> BackendTerminalAccessibilitySnapshot
    func activateTerminalAccessibilityLink(
        presentationID: PresentationID,
        expectedGeneration: UInt64,
        terminalRevision: UInt64,
        contentRevision: UInt64,
        viewportRevision: UInt64,
        linkID: String
    ) async throws -> BackendTerminalAccessibilityLinkActivation
    func terminalHyperlinkAtCell(
        presentationID: PresentationID,
        expectedGeneration: UInt64,
        expectedContentSequence: UInt64,
        column: UInt16,
        row: UInt16
    ) async throws -> BackendTerminalHyperlinkHit
    func performTerminalBindingAction(
        surfaceID: SurfaceID,
        action: String,
        repeatCount: UInt32?
    ) async throws -> BackendTerminalActionResponse
    func terminalSelection(
        surfaceID: SurfaceID,
        operation: BackendTerminalSelectionOperation
    ) async throws -> BackendTerminalSelectionResponse
    func terminalCopyMode(
        surfaceID: SurfaceID,
        operation: BackendTerminalCopyModeOperation,
        adjustment: BackendTerminalCopyModeAdjustment?,
        count: UInt32?
    ) async throws -> BackendTerminalActionResponse
    func terminalSearch(
        surfaceID: SurfaceID,
        operation: BackendTerminalSearchOperation,
        query: String?
    ) async throws -> BackendTerminalActionResponse
    func terminalScroll(
        surfaceID: SurfaceID,
        operation: BackendTerminalScrollOperation,
        amount: Int64?
    ) async throws -> BackendTerminalActionResponse
    func resizeTerminal(
        surface: UInt64,
        columns: UInt16,
        rows: UInt16
    ) async throws -> BackendSurfaceResizeResponse
    func readTerminalScreen(surface: UInt64) async throws -> BackendScreenText
    func terminalProcessInfo(surface: UInt64) async throws -> BackendProcessInfo
    func closeTerminal(surface: UInt64) async throws
}

extension TerminalBackendSessionServing {
    func makeTopologyMutationExpectation(
        requestID: UUID,
        authority: BackendAuthority,
        revision: UInt64
    ) async throws -> BackendTopologyMutationExpectation {
        _ = requestID
        _ = authority
        _ = revision
        throw BackendProtocolError.notConnected
    }

    func newWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        name: String?,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        _ = expectation
        _ = workspaceID
        _ = surfaceID
        _ = name
        _ = launch
        _ = columns
        _ = rows
        throw BackendProtocolError.notConnected
    }

    func newTerminalTab(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        _ = expectation
        _ = paneID
        _ = surfaceID
        _ = launch
        _ = columns
        _ = rows
        throw BackendProtocolError.notConnected
    }

    func newBrowserWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        name: String?,
        url: URL,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        _ = expectation
        _ = workspaceID
        _ = surfaceID
        _ = name
        _ = url
        _ = columns
        _ = rows
        throw BackendProtocolError.notConnected
    }

    func newBrowserTab(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        url: URL,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        _ = expectation
        _ = paneID
        _ = surfaceID
        _ = url
        _ = columns
        _ = rows
        throw BackendProtocolError.notConnected
    }

    func splitBrowserPane(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        direction: BackendSplitDirection,
        initialRatio: Float,
        url: URL,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        _ = expectation
        _ = paneID
        _ = surfaceID
        _ = direction
        _ = initialRatio
        _ = url
        _ = columns
        _ = rows
        throw BackendProtocolError.notConnected
    }

    func materializeTerminal(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        _ = expectation
        _ = workspaceID
        _ = surfaceID
        _ = launch
        _ = columns
        _ = rows
        throw BackendProtocolError.notConnected
    }

    func respawnTerminal(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        _ = expectation
        _ = surfaceID
        _ = launch
        _ = columns
        _ = rows
        throw BackendProtocolError.notConnected
    }

    func splitPane(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceID: SurfaceID,
        direction: BackendSplitDirection,
        initialRatio: Float,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        _ = expectation
        _ = paneID
        _ = surfaceID
        _ = direction
        _ = initialRatio
        _ = launch
        _ = columns
        _ = rows
        throw BackendProtocolError.notConnected
    }

    func splitTab(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        paneID: PaneID,
        direction: BackendSplitDirection,
        initialRatio: Float
    ) async throws -> BackendSurfacePlacement {
        _ = expectation
        _ = surfaceID
        _ = paneID
        _ = direction
        _ = initialRatio
        throw BackendProtocolError.notConnected
    }

    func closePane(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID
    ) async throws -> BackendTopologyMutationReceipt {
        _ = expectation
        _ = paneID
        throw BackendProtocolError.notConnected
    }

    func closeWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID
    ) async throws -> BackendTopologyMutationReceipt {
        _ = expectation
        _ = workspaceID
        throw BackendProtocolError.notConnected
    }

    func renameWorkspace(
        expectation: BackendTopologyMutationExpectation,
        workspaceID: WorkspaceID,
        name: String
    ) async throws -> BackendTopologyMutationReceipt {
        _ = expectation
        _ = workspaceID
        _ = name
        throw BackendProtocolError.notConnected
    }

    func renameSurface(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        name: String
    ) async throws -> BackendTopologyMutationReceipt {
        _ = expectation
        _ = surfaceID
        _ = name
        throw BackendProtocolError.notConnected
    }

    func moveTab(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        paneID: PaneID,
        index: UInt64
    ) async throws -> BackendTopologyMutationReceipt {
        _ = expectation
        _ = surfaceID
        _ = paneID
        _ = index
        throw BackendProtocolError.notConnected
    }

    func reorderTabs(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        surfaceIDs: [SurfaceID]
    ) async throws -> BackendTopologyMutationReceipt {
        _ = expectation
        _ = paneID
        _ = surfaceIDs
        throw BackendProtocolError.notConnected
    }

    func reorderWorkspaces(
        expectation: BackendTopologyMutationExpectation,
        workspaceIDs: [WorkspaceID]
    ) async throws -> BackendTopologyMutationReceipt {
        _ = expectation
        _ = workspaceIDs
        throw BackendProtocolError.notConnected
    }

    func moveTabToNewWorkspace(
        expectation: BackendTopologyMutationExpectation,
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID,
        name: String?,
        index: UInt64?
    ) async throws -> BackendSurfacePlacement {
        _ = expectation
        _ = surfaceID
        _ = workspaceID
        _ = name
        _ = index
        throw BackendProtocolError.notConnected
    }

    func setSplitRatio(
        expectation: BackendTopologyMutationExpectation,
        paneID: PaneID,
        direction: BackendSplitDirection,
        ratio: Float
    ) async throws -> BackendTopologyMutationReceipt {
        _ = expectation
        _ = paneID
        _ = direction
        _ = ratio
        throw BackendProtocolError.notConnected
    }

    func backendCompatibility() async throws -> BackendCompatibilityResult {
        throw BackendProtocolError.notConnected
    }

    func currentTerminalActivitySnapshot() async -> BackendTerminalActivitySnapshot? {
        nil
    }

    func markTerminalSeen(
        surfaceID: SurfaceID,
        activitySequence: UInt64
    ) async throws -> BackendTerminalActivityReceipt {
        _ = surfaceID
        _ = activitySequence
        throw BackendProtocolError.notConnected
    }

    func acquireTerminalLease(
        kind: BackendTerminalLeaseKind,
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        ttlMilliseconds: UInt64
    ) async throws -> BackendTerminalLease {
        _ = kind
        _ = surfaceID
        _ = presentationID
        _ = presentationGeneration
        _ = ttlMilliseconds
        throw BackendProtocolError.notConnected
    }

    func releaseTerminalLease(
        kind: BackendTerminalLeaseKind,
        surfaceID: SurfaceID,
        presentationID: PresentationID,
        presentationGeneration: UInt64
    ) async throws {
        _ = kind
        _ = surfaceID
        _ = presentationID
        _ = presentationGeneration
        throw BackendProtocolError.notConnected
    }

    func terminalRequestStatus(
        surfaceID: SurfaceID,
        requestID: UUID
    ) async throws -> BackendTerminalOperationReceipt {
        _ = surfaceID
        _ = requestID
        throw BackendProtocolError.notConnected
    }

    func acknowledgeTerminalRequest(
        surfaceID: SurfaceID,
        requestID: UUID
    ) async throws -> Bool {
        _ = surfaceID
        _ = requestID
        throw BackendProtocolError.notConnected
    }

    func setTerminalPreedit(
        presentationID: PresentationID,
        rendererGeneration: UInt64,
        preedit: BackendTerminalPreedit?
    ) async throws {
        try await setTerminalPreedit(
            presentationID: presentationID,
            rendererGeneration: rendererGeneration,
            text: preedit?.text
        )
    }

    /// Compatibility path for focused session doubles. The production
    /// `BackendCanonicalSession` supplies the single-command batch witness.
    func ensureTerminals(
        _ requests: [BackendEnsureTerminalRequest]
    ) async throws -> [BackendEnsuredTerminalPlacement] {
        var placements: [BackendEnsuredTerminalPlacement] = []
        placements.reserveCapacity(requests.count)
        for request in requests {
            placements.append(try await ensureTerminal(
                workspaceID: request.workspaceID,
                surfaceID: request.surfaceID,
                workingDirectory: request.workingDirectory,
                command: request.command,
                arguments: request.arguments,
                environment: request.environment,
                initialInput: request.initialInput,
                waitAfterCommand: request.waitAfterCommand,
                columns: request.columns,
                rows: request.rows
            ))
        }
        return placements
    }

    func terminalAccessibilitySnapshot(
        presentationID: PresentationID,
        expectedGeneration: UInt64,
        expectedContentSequence: UInt64
    ) async throws -> BackendTerminalAccessibilitySnapshot {
        _ = presentationID
        _ = expectedGeneration
        _ = expectedContentSequence
        throw BackendProtocolError.notConnected
    }

    func activateTerminalAccessibilityLink(
        presentationID: PresentationID,
        expectedGeneration: UInt64,
        terminalRevision: UInt64,
        contentRevision: UInt64,
        viewportRevision: UInt64,
        linkID: String
    ) async throws -> BackendTerminalAccessibilityLinkActivation {
        _ = presentationID
        _ = expectedGeneration
        _ = terminalRevision
        _ = contentRevision
        _ = viewportRevision
        _ = linkID
        throw BackendProtocolError.notConnected
    }

    func terminalHyperlinkAtCell(
        presentationID: PresentationID,
        expectedGeneration: UInt64,
        expectedContentSequence: UInt64,
        column: UInt16,
        row: UInt16
    ) async throws -> BackendTerminalHyperlinkHit {
        _ = presentationID
        _ = expectedGeneration
        _ = expectedContentSequence
        _ = column
        _ = row
        throw BackendProtocolError.notConnected
    }
}

extension BackendCanonicalSession: TerminalBackendSessionServing {}
