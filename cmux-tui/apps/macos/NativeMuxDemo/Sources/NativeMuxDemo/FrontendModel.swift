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
    @ObservationIgnored private var terminalControllers: [String: NativeTerminalModel] = [:]
    @ObservationIgnored private let shouldAutoConnect: Bool
    @ObservationIgnored private var didAutoConnect = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var machineID: String?
    @ObservationIgnored private var sessionID: String?

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
            errorMessage = L10n.text("connection.invitation", "Enrollment invitation")
            return
        }
        isConnecting = true
        errorMessage = ""
        Task {
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
                beginResourceUpdates(service: service)
                let streamID = "stream_" + UUID().uuidString
                    .replacingOccurrences(of: "-", with: "")
                    .lowercased()
                try await service.requestDiscardingResult(
                    "session.events",
                    params: [
                        "machine": .string(machine.id),
                        "session": .string(session.id),
                        "stream_id": .string(streamID),
                    ]
                )
                transportDiagnostics = await service.diagnostics()
                isConnecting = false
            } catch {
                await disconnectAfterFailure(error)
            }
        }
    }

    private func disconnectAfterFailure(_ error: any Error) async {
        let owned = service
        service = nil
        if let owned {
            await owned.shutdown()
        }
        isConnecting = false
        errorMessage = error.localizedDescription
    }

    private func beginResourceUpdates(service: FrontendService) {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            let updates = await service.updates()
            for await _ in updates.stream {
                guard !Task.isCancelled else { break }
                self?.scheduleRefresh()
            }
            await service.stopUpdates(generation: updates.generation)
        }
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(24))
            guard let self, !Task.isCancelled else { return }
            defer { refreshTask = nil }
            do {
                try await refreshNow()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshNow() async throws {
        guard let service, let machineID, let sessionID else { return }
        let next: ResourceSnapshot = try await service.request(
            "session.snapshot",
            params: [
                "machine": .string(machineID),
                "session": .string(sessionID),
            ]
        )
        snapshot = next
        reconcileSelection(next)
        pruneTerminalControllers(next)
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

    private func pruneTerminalControllers(_ next: ResourceSnapshot) {
        let live = Set(next.terminals.map(\.id))
        let removed = terminalControllers.keys.filter { !live.contains($0) }
        for id in removed {
            let controller = terminalControllers.removeValue(forKey: id)
            controller?.shutdown()
        }
    }

    func terminalController(for terminal: TerminalSnapshot) -> NativeTerminalModel? {
        guard let service else { return nil }
        if let controller = terminalControllers[terminal.id] {
            return controller
        }
        let controller = NativeTerminalModel(terminalID: terminal.id, service: service)
        terminalControllers[terminal.id] = controller
        controller.attach()
        return controller
    }

    func selectWorkspace(_ workspace: WorkspaceSnapshot) {
        selectedWorkspaceID = workspace.id
        selectedScreenID = snapshot?.screens(in: workspace.id).first { $0.focused }?.id
            ?? snapshot?.screens(in: workspace.id).first?.id
        mutate(
            "workspace.focus",
            selectors: ["workspace": workspace.id]
        )
    }

    func selectScreen(_ screen: ScreenSnapshot) {
        selectedScreenID = screen.id
        mutate(
            "screen.focus",
            selectors: ["workspace": screen.workspaceID, "screen": screen.id]
        )
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
        fields: [String: JSONValue] = [:]
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
                try await refreshNow()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func clearError() {
        errorMessage = ""
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        updatesTask?.cancel()
        refreshTask?.cancel()
        let controllers = Array(terminalControllers.values)
        terminalControllers.removeAll()
        let ownedService = service
        service = nil
        snapshot = nil
        Task {
            for controller in controllers {
                await controller.shutdownAndWait()
            }
            await ownedService?.shutdown()
        }
    }
}
