import CmuxTerminalBackend

/// Test seam over one exact credential-fenced canonical daemon connection.
protocol TerminalBackendSessionServing: Sendable {
    func events() async -> AsyncStream<BackendCanonicalSessionEvent>
    func connect() async throws -> TopologySnapshot
    func close() async

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
    func reparentTerminal(
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID
    ) async throws -> BackendReparentedTerminalPlacement

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
    func releaseRendererFrame(
        _ release: BackendRendererFrameRelease
    ) async throws -> BackendRendererFrameReleaseResponse
    func rendererWorkers() async throws -> BackendRendererWorkersResponse

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

extension BackendCanonicalSession: TerminalBackendSessionServing {}
