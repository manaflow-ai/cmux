import Foundation
import Observation

struct DemoLaunchConfiguration: Sendable {
    let invitation: String
    let autoConnect: Bool

    static func processEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DemoLaunchConfiguration {
        let invitation = environment["CMUX_NATIVE_INVITATION_FILE"]
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? ""
        return DemoLaunchConfiguration(
            invitation: invitation,
            autoConnect: environment["CMUX_NATIVE_AUTOCONNECT"] == "1"
        )
    }
}

@MainActor
@Observable
final class FrontendModel {
    var invitation: String
    private(set) var snapshot: ResourceSnapshot?
    private(set) var isConnecting = false
    private(set) var errorMessage = ""
    private(set) var transportDiagnostics = ""
    private(set) var selectedWorkspaceID: String?
    private(set) var selectedScreenID: String?

    @ObservationIgnored private var service: FrontendService?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var terminalControllers: [String: NativeTerminalModel] = [:]
    @ObservationIgnored private var terminalRetirementTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private lazy var ghosttyRuntime = NativeGhosttyRuntime()
    @ObservationIgnored private let shouldAutoConnect: Bool
    @ObservationIgnored private var didAutoConnect = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var machineID: String?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var focusMutations = FocusMutationTracker()

    init(configuration: DemoLaunchConfiguration = .processEnvironment()) {
        invitation = configuration.invitation
        shouldAutoConnect = configuration.autoConnect
    }

    var isConnected: Bool { service != nil && snapshot != nil }

    var selectedWorkspace: WorkspaceSnapshot? {
        guard let snapshot else { return nil }
        return snapshot.workspaces.first { $0.id == selectedWorkspaceID }
            ?? snapshot.workspaces.first { $0.focused }
            ?? snapshot.workspaces.first
    }

    var selectedScreen: ScreenSnapshot? {
        guard let snapshot, let workspace = selectedWorkspace else { return nil }
        let screens = snapshot.screens(in: workspace.id)
        return screens.first { $0.id == selectedScreenID }
            ?? screens.first { $0.focused }
            ?? screens.first
    }

    func connectIfConfigured() {
        guard shouldAutoConnect, !didAutoConnect else { return }
        didAutoConnect = true
        connect()
    }

    func connect() {
        guard !isConnecting, !isShuttingDown else { return }
        let invitation = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !invitation.isEmpty else {
            errorMessage = L10n.text(
                "connection.invitation.required",
                "Enter an enrollment invitation."
            )
            return
        }
        isConnecting = true
        errorMessage = ""
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let service = try await FrontendService.connect(invitation: invitation)
                guard !isShuttingDown else {
                    await service.shutdown()
                    return
                }
                self.service = service
                let machines: [ResourceIdentity] = try await service.request(
                    "machine.list",
                    params: [:]
                )
                guard let machine = machines.first else {
                    throw FrontendServiceError.message(
                        L10n.text("error.no_machine", "The daemon reported no machine.")
                    )
                }
                let sessions: [ResourceIdentity] = try await service.request(
                    "session.list",
                    params: ["machine": .string(machine.id)]
                )
                guard let session = sessions.first else {
                    throw FrontendServiceError.message(
                        L10n.text("error.no_session", "The daemon reported no session.")
                    )
                }
                machineID = machine.id
                sessionID = session.id
                try await refreshNow()
                let updates = await service.updates()
                do {
                    try await openResourceStream(
                        service: service,
                        machineID: machine.id,
                        sessionID: session.id
                    )
                } catch {
                    await service.stopUpdates(generation: updates.generation)
                    throw error
                }
                beginResourceUpdates(service: service, initialUpdates: updates)
                transportDiagnostics = await service.diagnostics()
                isConnecting = false
            } catch {
                await disconnectAfterFailure(error)
            }
            connectTask = nil
        }
    }

    private func disconnectAfterFailure(_ error: any Error) async {
        updatesTask?.cancel()
        refreshTask?.cancel()
        refreshRequested = false
        let controllers = Array(terminalControllers.values)
        let retirements = Array(terminalRetirementTasks.values)
        terminalControllers.removeAll()
        terminalRetirementTasks.removeAll()
        snapshot = nil
        machineID = nil
        sessionID = nil
        focusMutations = FocusMutationTracker()
        let owned = service
        service = nil
        for controller in controllers {
            await controller.shutdownAndWait()
        }
        for retirement in retirements {
            await retirement.value
        }
        if let owned {
            await owned.shutdown()
        }
        isConnecting = false
        errorMessage = error.localizedDescription
    }

    private func openResourceStream(
        service: FrontendService,
        machineID: String,
        sessionID: String
    ) async throws {
        let streamID = "stream_" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        try await service.requestDiscardingResult(
            "session.events",
            params: [
                "machine": .string(machineID),
                "session": .string(sessionID),
                "stream_id": .string(streamID),
            ]
        )
    }

    private func beginResourceUpdates(
        service: FrontendService,
        initialUpdates: FrontendUpdateSubscription
    ) {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            var updates = initialUpdates
            while !Task.isCancelled {
                var endReason = FrontendResourceStreamEndReason.none
                for await _ in updates.stream {
                    guard !Task.isCancelled else { break }
                    guard let self else { continue }
                    let batch = await service.drainResourceUpdates()
                    if batch.overflowed || (batch.envelopes.isEmpty && !batch.ended) {
                        self.scheduleRefresh()
                    } else if batch.envelopes.contains(where: { self.applyResourceDelta($0) == false }) {
                        // The projection accepts snapshots during bootstrap/resync.
                        // Delta application is deliberately fail-closed until every
                        // resource kind has a typed projection adapter.
                        self.scheduleRefresh()
                    }
                    if batch.ended {
                        endReason = batch.endReason
                        break
                    }
                }
                await service.stopUpdates(generation: updates.generation)
                guard !Task.isCancelled, let self else { return }
                guard endReason == .gap else {
                    await self.disconnectAfterFailure(
                        FrontendServiceError.message(L10n.text(
                            "error.session_event_stream_ended",
                            "The session event stream ended."
                        ))
                    )
                    return
                }
                do {
                    refreshRequested = false
                    let pendingRefresh = refreshTask
                    pendingRefresh?.cancel()
                    await pendingRefresh?.value
                    try await self.refreshNow()
                    guard let machineID = self.machineID, let sessionID = self.sessionID else {
                        return
                    }
                    updates = await service.updates()
                    do {
                        try await self.openResourceStream(
                            service: service,
                            machineID: machineID,
                            sessionID: sessionID
                        )
                    } catch {
                        await service.stopUpdates(generation: updates.generation)
                        throw error
                    }
                } catch {
                    await self.disconnectAfterFailure(error)
                    return
                }
            }
        }
    }

    private func applyResourceDelta(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = object["item"] as? [String: Any],
              item["kind"] as? String == "delta",
              let changes = item["changes"] as? [[String: Any]],
              let revision = item["revision"] as? String,
              let previous = item["previous_revision"] as? String,
              revision != previous else { return false }
        guard var next = snapshot else { return false }
        guard next.cursor.revision == previous else { return false }
        for change in changes {
            guard let resource = change["resource"] as? String,
                  let kind = change["kind"] as? String,
                  let id = change["id"] as? String else { return false }
            guard resource == "terminal" else { return false }
            if kind == "delete" {
                next.removeTerminal(id: id)
            } else if kind == "upsert",
                      let value = change["value"],
                      JSONSerialization.isValidJSONObject(value),
                      let encoded = try? JSONSerialization.data(withJSONObject: value),
                      let terminal = try? JSONDecoder().decode(TerminalSnapshot.self, from: encoded) {
                next.upsertTerminal(terminal)
            } else {
                return false
            }
        }
        next.setRevision(revision)
        snapshot = next
        reconcileTerminalControllers(next)
        return true
    }

    private func scheduleRefresh() {
        refreshRequested = true
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer { refreshTask = nil }
            while refreshRequested, !Task.isCancelled {
                refreshRequested = false
                do {
                    try await refreshNow()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func refreshNow() async throws {
        guard let service, let machineID, let sessionID else { return }
        let next = try await fetchSnapshot(
            service: service,
            machineID: machineID,
            sessionID: sessionID
        )
        snapshot = next
        reconcileSelection(next)
        reconcileTerminalControllers(next)
    }

    private func fetchSnapshot(
        service: FrontendService,
        machineID: String,
        sessionID: String
    ) async throws -> ResourceSnapshot {
        try await service.request(
            "session.snapshot",
            params: [
                "machine": .string(machineID),
                "session": .string(sessionID),
            ]
        )
    }

    private func reconcileSelection(_ next: ResourceSnapshot) {
        if selectedWorkspaceID.flatMap({ id in next.workspaces.first { $0.id == id } }) == nil {
            selectedWorkspaceID = next.workspaces.first { $0.focused }?.id
                ?? next.workspaces.first?.id
        }
        guard let selectedWorkspaceID else {
            selectedScreenID = nil
            return
        }
        let screens = next.screens(in: selectedWorkspaceID)
        if selectedScreenID.flatMap({ id in screens.first { $0.id == id } }) == nil {
            selectedScreenID = screens.first { $0.focused }?.id ?? screens.first?.id
        }
    }

    private func reconcileTerminalControllers(_ next: ResourceSnapshot) {
        let live = Set(next.terminals.map(\.id))
        let visible: Set<String> = {
            guard selectedWorkspaceID != nil,
                  let screenID = selectedScreenID else { return [] }
            let paneIDs = Set(next.panes.filter { $0.screenID == screenID }.map(\.id))
            let tabsByPane = Dictionary(grouping: next.tabs.filter { paneIDs.contains($0.paneID) }, by: \.paneID)
            let activeContentIDs = Set(tabsByPane.values.compactMap { tabs in
                (tabs.first { $0.focused } ?? tabs.first)?.contentID
            })
            return Set(next.terminals.map(\.id).filter { activeContentIDs.contains($0) })
        }()
        let removed = terminalControllers.keys.filter { !live.contains($0) || !visible.contains($0) }
        for id in removed {
            guard let controller = terminalControllers.removeValue(forKey: id) else { continue }
            retireTerminalController(controller)
        }
        guard let service else { return }
        for terminal in next.terminals where visible.contains(terminal.id) {
            guard terminalControllers[terminal.id] == nil else { continue }
            let controller = NativeTerminalModel(
                terminalID: terminal.id,
                service: service,
                runtime: ghosttyRuntime
            )
            terminalControllers[terminal.id] = controller
            controller.attach()
        }
    }

    private func retireTerminalController(_ controller: NativeTerminalModel) {
        let retirementID = UUID()
        terminalRetirementTasks[retirementID] = Task { [weak self] in
            await controller.shutdownAndWait()
            self?.terminalRetirementTasks[retirementID] = nil
        }
    }

    func terminalViewStates() -> [String: NativeTerminalViewState] {
        terminalControllers.mapValues(\.viewState)
    }

    func selectWorkspace(_ workspace: WorkspaceSnapshot) {
        let screenID = snapshot?.screens(in: workspace.id).first { $0.focused }?.id
            ?? snapshot?.screens(in: workspace.id).first?.id
        mutateFocus(
            "workspace.focus",
            selectors: ["workspace": workspace.id],
            workspaceID: workspace.id,
            screenID: screenID
        )
    }

    func selectScreen(_ screen: ScreenSnapshot) {
        mutateFocus(
            "screen.focus",
            selectors: ["workspace": screen.workspaceID, "screen": screen.id],
            workspaceID: screen.workspaceID,
            screenID: screen.id
        )
    }

    private func mutateFocus(
        _ operation: String,
        selectors: [String: String],
        workspaceID: String,
        screenID: String?
    ) {
        let requestID = focusMutations.begin(
            workspaceID: selectedWorkspaceID,
            screenID: selectedScreenID
        )
        selectedWorkspaceID = workspaceID
        selectedScreenID = screenID
        if let snapshot { reconcileTerminalControllers(snapshot) }
        mutate(
            operation,
            selectors: selectors,
            onSuccess: { await self.reconcileFocusMutation(requestID) },
            onFailure: {
                guard let rollback = self.focusMutations.rollback(requestID) else { return false }
                self.selectedWorkspaceID = rollback.workspaceID
                self.selectedScreenID = rollback.screenID
                if let snapshot = self.snapshot {
                    self.reconcileTerminalControllers(snapshot)
                }
                self.scheduleRefresh()
                return true
            }
        )
    }

    private func reconcileFocusMutation(_ requestID: UInt64) async {
        guard focusMutations.owns(requestID),
              let service,
              let machineID,
              let sessionID else { return }
        do {
            let next = try await fetchSnapshot(
                service: service,
                machineID: machineID,
                sessionID: sessionID
            )
            guard focusMutations.owns(requestID) else { return }
            snapshot = next
            selectedWorkspaceID = next.workspaces.first { $0.focused }?.id
                ?? next.workspaces.first?.id
            if let selectedWorkspaceID {
                let screens = next.screens(in: selectedWorkspaceID)
                selectedScreenID = screens.first { $0.focused }?.id ?? screens.first?.id
            } else {
                selectedScreenID = nil
            }
            _ = focusMutations.finish(requestID)
            reconcileTerminalControllers(next)
        } catch {
            guard focusMutations.finish(requestID) else { return }
            errorMessage = error.localizedDescription
            scheduleRefresh()
        }
    }

    func createWorkspace() {
        mutate(
            "workspace.create",
            selectors: [:],
            fields: [
                "name": .string(L10n.text("workspace.default_name", "workspace")),
                "initial_content": .string("terminal"),
            ]
        )
    }

    func closeWorkspace(_ workspace: WorkspaceSnapshot) {
        mutate("workspace.close", selectors: ["workspace": workspace.id])
    }

    func createScreen() {
        guard let workspace = selectedWorkspace else { return }
        mutate(
            "screen.create",
            selectors: ["workspace": workspace.id],
            fields: [
                "name": .string(L10n.format(
                    "space.default_name",
                    "space %d",
                    (snapshot?.screens(in: workspace.id).count ?? 0) + 1
                ))
            ]
        )
    }

    func closeScreen(_ screen: ScreenSnapshot) {
        mutate(
            "screen.close",
            selectors: ["workspace": screen.workspaceID, "screen": screen.id]
        )
    }

    func createAutoPane() {
        guard let screen = selectedScreen else { return }
        mutate(
            "pane.create",
            selectors: ["workspace": screen.workspaceID, "screen": screen.id]
        )
    }

    func splitPane(_ paneID: String, direction: String) {
        guard let screen = selectedScreen else { return }
        mutate(
            "pane.split",
            selectors: [
                "workspace": screen.workspaceID,
                "screen": screen.id,
                "pane": paneID,
            ],
            fields: ["direction": .string(direction), "ratio": .number(0.5)]
        )
    }

    func setSplitRatio(paneID: String, splitID: String, ratio: Double) {
        guard let screen = selectedScreen else { return }
        mutate(
            "pane.split_ratio.set",
            selectors: [
                "workspace": screen.workspaceID,
                "screen": screen.id,
                "pane": paneID,
            ],
            fields: [
                "split_id": .string(splitID),
                "ratio": .number(min(0.9, max(0.1, ratio))),
            ]
        )
    }

    func setViewportWidth(paneID: String, columns: Int) {
        guard let screen = selectedScreen else { return }
        mutate(
            "pane.viewport_width.set",
            selectors: [
                "workspace": screen.workspaceID,
                "screen": screen.id,
                "pane": paneID,
            ],
            fields: ["columns": .integer(min(10_000, max(1, columns)))]
        )
    }

    func createNiriColumn(after paneID: String) {
        guard let screen = selectedScreen else { return }
        mutate(
            "pane.split",
            selectors: [
                "workspace": screen.workspaceID,
                "screen": screen.id,
                "pane": paneID,
            ],
            fields: [
                "direction": .string("right"),
                "viewport_width": .number(0.55),
            ]
        )
    }

    func focusPane(_ paneID: String) {
        guard let screen = selectedScreen else { return }
        mutate(
            "pane.focus",
            selectors: [
                "workspace": screen.workspaceID,
                "screen": screen.id,
                "pane": paneID,
            ]
        )
    }

    func zoomPane(_ paneID: String, enabled: Bool) {
        guard let screen = selectedScreen else { return }
        mutate(
            "pane.zoom",
            selectors: [
                "workspace": screen.workspaceID,
                "screen": screen.id,
                "pane": paneID,
            ],
            fields: ["enabled": .bool(enabled)]
        )
    }

    func closePane(_ paneID: String) {
        guard let screen = selectedScreen else { return }
        mutate(
            "pane.close",
            selectors: [
                "workspace": screen.workspaceID,
                "screen": screen.id,
                "pane": paneID,
            ]
        )
    }

    func createTerminalTab(in paneID: String) {
        guard let screen = selectedScreen else { return }
        mutate(
            "tab.create_terminal",
            selectors: [
                "workspace": screen.workspaceID,
                "screen": screen.id,
                "pane": paneID,
            ]
        )
    }

    func createBrowserTab(in paneID: String) {
        guard let screen = selectedScreen else { return }
        mutate(
            "tab.create_browser",
            selectors: [
                "workspace": screen.workspaceID,
                "screen": screen.id,
                "pane": paneID,
            ],
            fields: ["url": .string("https://example.com")]
        )
    }

    func focusTab(_ tab: TabSnapshot) {
        guard let screen = selectedScreen else { return }
        mutate(
            "tab.focus",
            selectors: [
                "workspace": screen.workspaceID,
                "screen": screen.id,
                "pane": tab.paneID,
                "tab": tab.id,
            ]
        )
    }

    func closeTab(_ tab: TabSnapshot) {
        guard let screen = selectedScreen else { return }
        mutate(
            "tab.close",
            selectors: [
                "workspace": screen.workspaceID,
                "screen": screen.id,
                "pane": tab.paneID,
                "tab": tab.id,
            ]
        )
    }

    private func mutate(
        _ operation: String,
        selectors: [String: String],
        fields: [String: JSONValue] = [:],
        onSuccess: (() async -> Void)? = nil,
        onFailure: (() -> Bool)? = nil
    ) {
        guard let service, let machineID, let sessionID else { return }
        var params: [String: JSONValue] = [
            "machine": .string(machineID),
            "session": .string(sessionID),
        ]
        for (key, value) in selectors { params[key] = .string(value) }
        for (key, value) in fields { params[key] = value }
        Task {
            do {
                try await service.requestDiscardingResult(
                    operation,
                    params: params,
                    mutation: true
                )
                if let onSuccess {
                    await onSuccess()
                } else {
                    scheduleRefresh()
                }
            } catch {
                if onFailure?() ?? true {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func clearError() {
        errorMessage = ""
    }

    func shutdown() {
        Task { @MainActor in
            await shutdownAndWait()
        }
    }

    func shutdownAndWait() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        connectTask?.cancel()
        updatesTask?.cancel()
        refreshTask?.cancel()
        refreshRequested = false
        focusMutations = FocusMutationTracker()
        let controllers = Array(terminalControllers.values)
        let retirements = Array(terminalRetirementTasks.values)
        terminalControllers.removeAll()
        terminalRetirementTasks.removeAll()
        let ownedService = service
        service = nil
        snapshot = nil
        for controller in controllers {
            await controller.shutdownAndWait()
        }
        for retirement in retirements {
            await retirement.value
        }
        await ownedService?.shutdown()
    }
}
