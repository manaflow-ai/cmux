public import CMUXMobileCore
public import CmuxMobilePairedMac
public import CmuxMobileRPC
public import CmuxMobileShellModel
internal import CmuxMobileSupport
public import CmuxMobileTransport
public import Foundation
import Observation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

/// Transitional alias for the decomposed shell facade.
///
/// The iOS views and push coordinator still bind to `CMUXMobileShellStore`;
/// this keeps those call sites compiling while the god store is dissolved into
/// composed coordinators behind ``MobileShellComposite``. Remove once every
/// consumer binds to ``MobileShellComposite`` directly.
public typealias CMUXMobileShellStore = MobileShellComposite

/// The decomposed home object the iOS shell views bind to.
///
/// Holds the connection lifecycle, network-recovery state machine,
/// workspace/terminal list state, and the render-grid-vs-raw-bytes terminal
/// output pipeline behind one `@Observable` read surface. Constructed at the
/// app composition root with its collaborators injected as protocol seams
/// (``MobileSyncRuntime``, ``MobilePairedMacStoring``, ``MobileIdentityProviding``,
/// ``ReachabilityProviding``, ``MobileClientIDRepository``).
@MainActor
@Observable
public final class MobileShellComposite: MobileTerminalOutputSinking {
    public private(set) var isSignedIn: Bool
    public var connectionState: MobileConnectionState { connection.connectionState }
    public var macConnectionStatus: MobileMacConnectionStatus { connection.macConnectionStatus }
    public var connectedHostName: String { connection.connectedHostName }
    public var connectionError: String? { connection.connectionError }
    public var activeTicket: CmxAttachTicket? { connection.activeTicket }
    public var activeRoute: CmxAttachRoute? { connection.activeRoute }
    public var hasActiveUnexpiredAttachTicket: Bool { connection.hasActiveUnexpiredAttachTicket }
    public var pairingCode: String {
        get { connection.pairingCode }
        set { connection.pairingCode = newValue }
    }
    public var terminalInputText: String
    public var workspaces: [MobileWorkspacePreview] {
        get { workspaceModel.workspaces }
        set { workspaceModel.workspaces = newValue }
    }
    public var selectedWorkspaceID: MobileWorkspacePreview.ID? {
        get { workspaceModel.selectedWorkspaceID }
        set { workspaceModel.selectedWorkspaceID = newValue }
    }
    public var selectedTerminalID: MobileTerminalPreview.ID? {
        get { workspaceModel.selectedTerminalID }
        set { workspaceModel.selectedTerminalID = newValue }
    }

    private let clientID: String
    /// The carved-out connection lifecycle (pairing, ticket minting, route
    /// selection, reconnect, disconnect, error localization). Internal so the
    /// package test target can drive it directly.
    let connection: MobileConnectionCoordinator
    /// The carved-out network-recovery state machine. Internal so the package
    /// test target can drive it directly.
    let recovery: MobileRecoveryCoordinator
    /// The carved-out workspace/terminal list + selection state. Internal so
    /// the package test target can drive it directly.
    let workspaceModel: MobileWorkspaceModel
    /// The carved-out terminal output pipeline (event listener, watchdog,
    /// sequence tracking, replay, per-surface output sinks). Internal so the
    /// package test target can drive it directly.
    let terminalOutput: MobileTerminalOutputService
    /// The active RPC client. Internal (not `private`) because it witnesses
    /// ``MobileTerminalOutputContext/remoteClient``.
    var remoteClient: MobileCoreRPCClient? { connection.remoteClient }
    private var createWorkspaceTask: Task<Void, Never>?
    private var createTerminalTask: Task<Void, Never>?
    private var createWorkspaceTaskID: UUID?
    private var createTerminalTaskID: UUID?
    // Internal (not `private`): cleared by the connection-context conformance.
    var rawTerminalInputBuffer: MobileTerminalInputSendBuffer

    public var phase: MobileShellPhase {
        if !isSignedIn {
            return .signIn
        }
        if connectionState != .connected {
            return .pairing
        }
        return .workspaces
    }

    public var selectedWorkspace: MobileWorkspacePreview? {
        workspaceModel.selectedWorkspace
    }

    public init(
        runtime: (any MobileSyncRuntime)? = nil,
        isSignedIn: Bool = false,
        connectionState: MobileConnectionState = .disconnected,
        connectedHostName: String = "",
        pairingCode: String = "",
        workspaces: [MobileWorkspacePreview] = [],
        pairedMacStore: (any MobilePairedMacStoring)? = nil,
        clientIDRepository: MobileClientIDRepository = MobileClientIDRepository(defaults: .standard),
        identityProvider: (any MobileIdentityProviding)? = nil,
        reachability: any ReachabilityProviding = ReachabilityService()
    ) {
        let recovery = MobileRecoveryCoordinator(reachability: reachability)
        self.recovery = recovery
        self.connection = MobileConnectionCoordinator(
            runtime: runtime,
            pairedMacStore: pairedMacStore,
            identityProvider: identityProvider,
            recovery: recovery,
            connectionState: connectionState,
            connectedHostName: connectedHostName,
            pairingCode: pairingCode
        )
        let clientID = clientIDRepository.clientID
        self.clientID = clientID
        self.workspaceModel = MobileWorkspaceModel(workspaces: workspaces)
        self.terminalOutput = MobileTerminalOutputService(runtime: runtime, clientID: clientID)
        self.isSignedIn = isSignedIn
        self.terminalInputText = ""
        self.createWorkspaceTask = nil
        self.createTerminalTask = nil
        self.createWorkspaceTaskID = nil
        self.createTerminalTaskID = nil
        self.rawTerminalInputBuffer = MobileTerminalInputSendBuffer()
        terminalOutput.bind(context: self)
        recovery.bind(context: self)
        connection.bind(context: self)
    }

    isolated deinit {
        // The carved pieces cancel their own listener/watchdog/observation/
        // refresh tasks (and disconnect the remote client) in their
        // `isolated deinit`s, which run when this facade (their only strong
        // owner) is deallocated.
        createWorkspaceTask?.cancel()
        createTerminalTask?.cancel()
    }

    public static func preview(runtime: (any MobileSyncRuntime)? = nil) -> CMUXMobileShellStore {
        CMUXMobileShellStore(runtime: runtime, workspaces: PreviewMobileHost.workspaces)
    }

    public func signIn() {
        isSignedIn = true
        connection.connectionError = nil
    }

    public func signOut() {
        isSignedIn = false
        connection.resetForSignOut()
        terminalInputText = ""
        rawTerminalInputBuffer.clear()
        terminalOutput.clearReportedViewports()
        workspaces = PreviewMobileHost.workspaces
        selectedWorkspaceID = workspaces.first?.id
        selectedTerminalID = workspaces.first?.terminals.first?.id
    }

    public func resumeForegroundRefresh() {
        recovery.startObservingNetworkPathChanges()
        terminalOutput.resyncTerminalOutput(reason: "foreground", restartEventStream: true)
    }

    /// Forward a scroll gesture to the Mac's real surface. libghostty does the
    /// mode-correct thing: normal screen moves the viewport into scrollback;
    /// alt screen + mouse reporting encodes mouse-wheel to the PTY for the
    /// program. The render-grid mirrors the result (it exports the live
    /// `vp_top`), so no local-mirror scroll or scrollback cache is needed.
    /// Fire-and-forget (called per display-link frame during a drag).
    public func scrollTerminal(surfaceID: String, lines: Double, col: Int, row: Int) async {
        guard lines != 0,
              let client = remoteClient,
              let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            return
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.scroll",
                params: [
                    "workspace_id": workspaceID.rawValue,
                    "surface_id": surfaceID,
                    "client_id": clientID,
                    "delta_lines": lines,
                    "col": col,
                    "row": row,
                ]
            )
            _ = try await client.sendRequest(request)
        } catch {
            mobileShellLog.error("scroll forward failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// Forward a tap to the Mac's real surface as a left click at the given grid
    /// cell. libghostty self-gates: a TUI with mouse reporting receives the
    /// click; a normal screen treats it as a harmless empty selection. The
    /// render-grid mirrors any resulting change back. Fire-and-forget.
    public func clickTerminal(surfaceID: String, col: Int, row: Int) async {
        guard let client = remoteClient,
              let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            return
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.mouse",
                params: [
                    "workspace_id": workspaceID.rawValue,
                    "surface_id": surfaceID,
                    "client_id": clientID,
                    "col": col,
                    "row": row,
                ]
            )
            _ = try await client.sendRequest(request)
        } catch {
            mobileShellLog.error("click forward failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Network recovery

    /// True while an automatic reconnect is in progress after a network change
    /// or drop.
    public var isRecoveringConnection: Bool {
        recovery.isRecoveringConnection
    }
    /// True when automatic recovery could not restore the connection; the UI
    /// surfaces a manual Retry control in this state.
    public var connectionRecoveryFailed: Bool {
        recovery.connectionRecoveryFailed
    }
    /// True when the host rejected this device on authorization grounds (the Mac
    /// is signed in to a different account, or the token could not be verified).
    /// Retrying cannot fix this, so the UI surfaces the auth message and a
    /// Sign Out action instead of a Retry control. ``connectionError`` carries
    /// the user-facing reason.
    public var connectionRequiresReauth: Bool {
        connection.connectionRequiresReauth
    }

    /// User-initiated reconnect from the Retry control.
    public func retryMobileConnection() {
        recovery.retryMobileConnection()
    }

    public func connectPreviewHost() {
        connection.connectPreviewHost()
    }

    public func connectPairingInput() async {
        await connection.connectPairingInput()
    }

    public func connectManualHost(name: String, host: String, port: Int) async {
        await connection.connectManualHost(name: name, host: host, port: port)
    }

    /// On launch (after StackAuth has bootstrapped), call this to reconnect
    /// to the last-active paired Mac. Pulls (route, displayName, macDeviceID)
    /// from SQLite and re-mints an attach ticket via the StackAuth-authenticated
    /// manual host flow. Auth tokens never persist; we always re-mint.
    @discardableResult
    public func reconnectActiveMacIfAvailable(stackUserID: String?) async -> Bool {
        recovery.prepareForReconnect(stackUserID: stackUserID)
        return await connection.reconnectActiveMacIfAvailable(stackUserID: stackUserID)
    }

    static func firstReconnectHostPortRoute(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind]
    ) -> (String, Int)? {
        MobileConnectionCoordinator.firstReconnectHostPortRoute(routes, supportedKinds: supportedKinds)
    }

    @discardableResult
    public func connectPairingURL(_ rawValue: String? = nil) async -> Bool {
        await connection.connectPairingURL(rawValue)
    }

    @discardableResult
    public func connectPairingURLResult(_ rawValue: String? = nil) async -> MobilePairingURLConnectionResult {
        await connection.connectPairingURLResult(rawValue)
    }

    public func cancelPairing() {
        connection.cancelPairing()
    }

    /// Disconnect from the currently paired Mac and forget it so the next
    /// session starts from a fresh QR scan. Clears in-memory state and the
    /// persisted active flag (other macs in SQLite stay, but none are marked
    /// active so reconnect-on-launch is a no-op until the user pairs again).
    public func disconnectAndForgetActiveMac() {
        connection.disconnectAndForgetActiveMac()
    }

    public func createWorkspace() {
        guard remoteClient == nil else {
            guard createWorkspaceTask == nil else { return }
            let taskID = UUID()
            createWorkspaceTaskID = taskID
            createWorkspaceTask = Task { @MainActor [weak self] in
                defer { self?.clearCreateWorkspaceTask(id: taskID) }
                guard let self else { return }
                await self.createRemoteWorkspace()
            }
            return
        }
        workspaceModel.appendLocalWorkspace()
    }

    public func createTerminal() {
        guard remoteClient == nil else {
            guard createTerminalTask == nil else { return }
            let taskID = UUID()
            createTerminalTaskID = taskID
            createTerminalTask = Task { @MainActor [weak self] in
                defer { self?.clearCreateTerminalTask(id: taskID) }
                guard let self else { return }
                await self.createRemoteTerminal()
            }
            return
        }
        workspaceModel.appendLocalTerminal()
    }

    public func selectTerminal(_ id: MobileTerminalPreview.ID?) {
        selectedTerminalID = id
    }

    public func reportTerminalViewport(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        viewportSize: MobileTerminalViewportSize
    ) {
        terminalOutput.reportTerminalViewport(
            workspaceID: workspaceID,
            terminalID: terminalID,
            viewportSize: viewportSize
        )
    }

    public func openWorkspace(_ id: MobileWorkspacePreview.ID) async {
        setSelectedWorkspaceID(id)
    }

    public func sendTerminalInput() {
        Task { @MainActor [weak self] in
            await self?.submitTerminalInput()
        }
    }

    public func submitTerminalInput() async {
        let text = terminalInputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        terminalInputText = ""
        guard remoteClient != nil else { return }
        await sendRemoteTerminalInput(text + "\r")
    }

    public func sendTerminalRawInput(_ text: String) {
        #if DEBUG
        mobileShellLog.debug("enqueue raw terminal input byteCount=\(text.utf8.count, privacy: .public)")
        #endif
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else {
            #if DEBUG
            mobileShellLog.info("skip raw terminal input enqueue selectedWorkspace=\(self.selectedWorkspace == nil ? 0 : 1, privacy: .public) selectedTerminal=\(self.selectedTerminalID == nil ? 0 : 1, privacy: .public)")
            #endif
            return
        }
        switch rawTerminalInputBuffer.enqueue(
            text,
            workspaceID: workspaceID,
            terminalID: terminalID
        ) {
        case .startDraining:
            Task { @MainActor [weak self] in
                await self?.drainRawTerminalInputBuffer()
            }
        case .queued:
            return
        case .rejected:
            mobileShellLog.error("disconnecting mobile terminal input because pending byte count exceeded limit")
            connection.disconnect(showingError: L10n.string(
                "mobile.terminal.inputQueueFull",
                defaultValue: "The terminal can't accept more input right now. Wait a moment and retry, or reopen the terminal if it stays unavailable."
            ))
        }
    }

    public func submitTerminalRawInput(_ text: String) async {
        guard !text.isEmpty else { return }
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else {
            return
        }
        await submitTerminalRawInput(text, workspaceID: workspaceID, terminalID: terminalID)
    }

    /// Raw-bytes overload. The libghostty render path on iOS uses this
    /// for input that may include binary sequences (mouse reports,
    /// kitty keyboard, IME byte streams). The wire RPC encodes bytes
    /// as the UTF-8-stringified payload of `mobile.terminal.input`,
    /// then the Mac decodes back to Data. If we ever need true binary
    /// fidelity (paste of mid-codepoint bytes, etc.), upgrade the
    /// `input` param to a base64 field.
    public func submitTerminalRawInput(_ data: Data, surfaceID: String) async {
        guard !data.isEmpty else { return }
        guard let text = String(data: data, encoding: .utf8) else {
            return
        }
        let workspaceCandidate = workspaces.first(where: { workspace in
            workspace.terminals.contains(where: { $0.id.rawValue == surfaceID })
        })
        guard let workspace = workspaceCandidate else { return }
        let terminalID = MobileTerminalPreview.ID(rawValue: surfaceID)
        await submitTerminalRawInput(text, workspaceID: workspace.id, terminalID: terminalID)
    }

    private func submitTerminalRawInput(
        _ text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async {
        guard !text.isEmpty else { return }
        guard remoteClient != nil else { return }
        await sendRemoteTerminalInput(text, workspaceID: workspaceID, terminalID: terminalID)
    }

    private func drainRawTerminalInputBuffer() async {
        while let chunk = rawTerminalInputBuffer.nextBatch() {
            await submitTerminalRawInput(
                chunk.text,
                workspaceID: chunk.workspaceID,
                terminalID: chunk.terminalID
            )
        }
    }

    // Internal (not `private`): witnesses ``MobileConnectionContext``.
    func cancelRemoteOperationTasks() {
        terminalOutput.cancelSubscriptionRefresh()
        createWorkspaceTask?.cancel()
        createWorkspaceTask = nil
        createWorkspaceTaskID = nil
        createTerminalTask?.cancel()
        createTerminalTask = nil
        createTerminalTaskID = nil
        connection.cancelWorkspaceListRefresh()
    }

    private func clearCreateWorkspaceTask(id: UUID) {
        guard createWorkspaceTaskID == id else { return }
        createWorkspaceTask = nil
        createWorkspaceTaskID = nil
    }

    private func clearCreateTerminalTask(id: UUID) {
        guard createTerminalTaskID == id else { return }
        createTerminalTask = nil
        createTerminalTaskID = nil
    }

    // Internal (not `private`): witnesses ``MobileTerminalOutputContext``.
    func markMacConnectionHealthy() {
        connection.markMacConnectionHealthy()
    }

    // Internal (not `private`): witnesses ``MobileTerminalOutputContext``.
    func markMacConnectionReconnecting() {
        connection.markMacConnectionReconnecting()
    }

    // Internal (not `private`): witnesses ``MobileTerminalOutputContext``.
    func markMacConnectionUnavailable() {
        connection.markMacConnectionUnavailable()
    }

    // Internal (not `private`): witnesses ``MobileConnectionContext``.
    func syncSelectedTerminalForWorkspace() {
        workspaceModel.syncSelectedTerminalForWorkspace()
    }

    private func createRemoteWorkspace() async {
        guard let client = remoteClient else { return }
        let generation = connection.connectionGeneration
        do {
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "workspace.create")
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            guard connection.isCurrentRemoteOperation(client: client, generation: generation),
                  !Task.isCancelled else { return }
            applyRemoteWorkspaceList(response, mergeExistingWorkspaces: true)
            if let createdID = response.createdWorkspaceID {
                let createdWorkspaceID = MobileWorkspacePreview.ID(rawValue: createdID)
                setSelectedWorkspaceID(createdWorkspaceID)
            }
            syncSelectedTerminalForWorkspace()
        } catch {
            guard generation == connection.connectionGeneration, !Task.isCancelled else { return }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            connection.markMacConnectionUnavailableIfNeeded(after: error)
            connection.reportConnectionError(error)
        }
    }

    private func createRemoteTerminal() async {
        guard let client = remoteClient,
              let workspaceID = selectedWorkspace?.id.rawValue else { return }
        let requestedWorkspaceID = MobileWorkspacePreview.ID(rawValue: workspaceID)
        let generation = connection.connectionGeneration
        do {
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.create",
                    params: ["workspace_id": workspaceID]
                )
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            guard connection.isCurrentRemoteOperation(client: client, generation: generation),
                  !Task.isCancelled else { return }
            applyRemoteWorkspaceList(response, mergeExistingWorkspaces: true)
            if selectedWorkspaceID == requestedWorkspaceID,
               let createdID = response.createdTerminalID {
                selectedTerminalID = MobileTerminalPreview.ID(rawValue: createdID)
            }
        } catch {
            guard generation == connection.connectionGeneration, !Task.isCancelled else { return }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            connection.markMacConnectionUnavailableIfNeeded(after: error)
            connection.reportConnectionError(error)
        }
    }

    private func sendRemoteTerminalInput(_ text: String) async {
        guard let workspaceID = selectedWorkspace?.id,
              let terminalID = selectedTerminalID else {
            #if DEBUG
            mobileShellLog.info("skip remote terminal input selectedWorkspace=\(self.selectedWorkspace == nil ? 0 : 1, privacy: .public) selectedTerminal=\(self.selectedTerminalID == nil ? 0 : 1, privacy: .public)")
            #endif
            return
        }
        await sendRemoteTerminalInput(text, workspaceID: workspaceID, terminalID: terminalID)
    }

    private func sendRemoteTerminalInput(
        _ text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async {
        guard let client = remoteClient else {
            #if DEBUG
            mobileShellLog.info("skip remote terminal input remoteClient=0")
            #endif
            return
        }
        let generation = connection.connectionGeneration
        do {
            #if DEBUG
            mobileShellLog.debug("send remote terminal input byteCount=\(text.utf8.count, privacy: .public) workspace=\(workspaceID.rawValue, privacy: .private) terminal=\(terminalID.rawValue, privacy: .private)")
            #endif
            var params: [String: Any] = [
                "workspace_id": workspaceID.rawValue,
                "surface_id": terminalID.rawValue,
                "text": text,
                "client_id": clientID,
            ]
            if let viewportSize = terminalOutput.reportedViewportSize(
                workspaceID: workspaceID,
                terminalID: terminalID
            ) {
                params["viewport_columns"] = viewportSize.columns
                params["viewport_rows"] = viewportSize.rows
            }
            let responseData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.input",
                    params: params
                )
            )
            guard connection.isCurrentRemoteOperation(client: client, generation: generation) else { return }
            terminalOutput.handleTerminalInputResponse(responseData, surfaceID: terminalID.rawValue)
        } catch {
            guard generation == connection.connectionGeneration else { return }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            connection.markMacConnectionUnavailableIfNeeded(after: error)
            connection.reportConnectionError(error)
        }
    }

    /// The output byte stream for a terminal surface.
    ///
    /// Obtaining the stream arms a cold-attach replay so the surface catches up
    /// to current state; ending iteration (or cancelling the consuming task)
    /// unregisters the surface and clears its viewport pin on the Mac.
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Returns: An `AsyncStream` of output byte chunks.
    public func terminalOutputStream(surfaceID: String) -> AsyncStream<Data> {
        terminalOutput.terminalOutputStream(surfaceID: surfaceID)
    }
    /// Report this device's natural terminal grid to the Mac and return the
    /// effective grid the Mac computed (the smallest across all attached
    /// devices, capped to the Mac pane). The caller pins its libghostty surface
    /// to that grid so every device renders the same cols×rows with a viewport
    /// border around the live area (tmux-style shared resize).
    public func updateTerminalViewport(
        surfaceID: String,
        columns: Int,
        rows: Int
    ) async -> (columns: Int, rows: Int)? {
        await terminalOutput.updateTerminalViewport(
            surfaceID: surfaceID,
            columns: columns,
            rows: rows
        )
    }

    /// Tell the Mac to drop this device's viewport pin for a surface (on
    /// detach). Fire-and-forget; the Mac also clears on connection close.
    public func clearTerminalViewport(surfaceID: String) {
        terminalOutput.clearTerminalViewport(surfaceID: surfaceID)
    }

    // Internal (not `private`): witnesses ``MobileTerminalOutputContext``.
    func workspaceID(forTerminalID terminalID: String) -> MobileWorkspacePreview.ID? {
        workspaceModel.workspaceID(forTerminalID: terminalID)
    }

    // Internal (not `private`): witnesses ``MobileTerminalOutputContext``.
    func scheduleWorkspaceListRefreshFromEvent() {
        connection.scheduleWorkspaceListRefreshFromEvent()
    }

    private func setSelectedWorkspaceID(_ id: MobileWorkspacePreview.ID?) {
        workspaceModel.setSelectedWorkspaceID(id)
    }

    // Internal (not `private`): witnesses ``MobileConnectionContext``.
    func applyRemoteWorkspaceList(
        _ response: MobileSyncWorkspaceListResponse,
        preferActiveTicketTarget: Bool = false,
        mergeExistingWorkspaces: Bool = false
    ) {
        workspaceModel.applyRemoteWorkspaceList(
            response,
            preferActiveTicketTarget: preferActiveTicketTarget,
            mergeExistingWorkspaces: mergeExistingWorkspaces,
            activeTicketWorkspaceID: activeTicket?.workspaceID,
            activeTicketTerminalID: activeTicket?.terminalID
        )
    }

    // Internal (not `private`): witnesses ``MobileTerminalOutputContext``.
    @discardableResult
    func disconnectForAuthorizationFailureIfNeeded(_ error: any Error) -> Bool {
        connection.disconnectForAuthorizationFailureIfNeeded(error)
    }

}
