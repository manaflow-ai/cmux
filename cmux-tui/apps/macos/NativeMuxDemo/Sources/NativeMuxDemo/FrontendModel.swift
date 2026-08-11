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

func uniqueFrontendIdentity(_ identities: [ResourceIdentity]) -> ResourceIdentity? {
    identities.count == 1 ? identities[0] : nil
}

struct FrontendResourceGeneration: Sendable {
    private(set) var value: UInt64 = 0

    var token: UInt64 { value }

    mutating func advance() {
        value &+= 1
    }

    func matches(_ token: UInt64) -> Bool {
        value == token
    }
}

struct FrontendRecoveryPolicy: Sendable {
    let maximumAttempts: Int
    let initialBackoffNanoseconds: UInt64

    static let standard = FrontendRecoveryPolicy(
        maximumAttempts: 3,
        initialBackoffNanoseconds: 100_000_000
    )

    func backoffNanoseconds(afterFailedAttempt attempt: Int) -> UInt64 {
        let shift = min(max(0, attempt), 2)
        return initialBackoffNanoseconds << shift
    }
}

typealias FrontendRecoveryDelay = @Sendable (UInt64) async throws -> Void

struct FrontendResourceStream: Sendable, Equatable {
    let id: String

    func cancellationParameters(machineID: String, sessionID: String) -> [String: JSONValue] {
        [
            "machine": .string(machineID),
            "session": .string(sessionID),
            "stream": .string(id),
        ]
    }
}

@MainActor
@Observable
final class TerminalTitleOwner {
    let terminalID: String
    private(set) var title: String

    @ObservationIgnored private var pendingTitle: String?
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?

    init(terminalID: String, title: String) {
        self.terminalID = terminalID
        self.title = title
    }

    func submit(_ nextTitle: String) {
        pendingTitle = nextTitle
        guard deliveryTask == nil else { return }
        deliveryTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            let latest = pendingTitle
            pendingTitle = nil
            deliveryTask = nil
            if let latest, latest != title { title = latest }
            if pendingTitle != nil { submit(pendingTitle ?? title) }
        }
    }

    func replace(with nextTitle: String) {
        deliveryTask?.cancel()
        deliveryTask = nil
        pendingTitle = nil
        if title != nextTitle { title = nextTitle }
    }

    func cancel() {
        deliveryTask?.cancel()
        deliveryTask = nil
        pendingTitle = nil
    }
}

@MainActor
struct TerminalTitleFn {
    private let owners: [String: TerminalTitleOwner]

    init(owners: [String: TerminalTitleOwner]) {
        self.owners = owners
    }

    func callAsFunction(_ terminalID: String) -> TerminalTitleOwner? {
        owners[terminalID]
    }
}

@MainActor
@Observable
final class FrontendModel {
    private static let maximumPendingMutations = 16

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
    @ObservationIgnored private var terminalControllers: [String: NativeTerminalModel] = [:]
    @ObservationIgnored private var terminalTitles: [String: TerminalTitleOwner] = [:]
    @ObservationIgnored private var terminalRetirementTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var mutationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var replaceableMutationIDs: [String: UUID] = [:]
    @ObservationIgnored private lazy var ghosttyRuntime = NativeGhosttyRuntime()
    @ObservationIgnored private let shouldAutoConnect: Bool
    @ObservationIgnored private var didAutoConnect = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var machineID: String?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var resourceRevision: String?
    @ObservationIgnored private var resourceState: ResourceSnapshot?
    @ObservationIgnored private var resourceGeneration = FrontendResourceGeneration()
    @ObservationIgnored private let resourceDecoder = FrontendResourceDecoder()
    @ObservationIgnored private var focusMutations = FocusMutationTracker()
    @ObservationIgnored private let recoveryPolicy: FrontendRecoveryPolicy
    @ObservationIgnored private let recoveryDelay: FrontendRecoveryDelay

    init(
        configuration: DemoLaunchConfiguration = .processEnvironment(),
        recoveryPolicy: FrontendRecoveryPolicy = .standard,
        recoveryDelay: @escaping FrontendRecoveryDelay = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        invitation = configuration.invitation
        shouldAutoConnect = configuration.autoConnect
        self.recoveryPolicy = recoveryPolicy
        self.recoveryDelay = recoveryDelay
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
                guard let machine = uniqueFrontendIdentity(machines) else {
                    throw FrontendServiceError.localized(
                        L10n.text(
                            "error.no_machine",
                            "The daemon did not identify exactly one machine."
                        )
                    )
                }
                let sessions: [ResourceIdentity] = try await service.request(
                    "session.list",
                    params: ["machine": .string(machine.id)]
                )
                guard let session = uniqueFrontendIdentity(sessions) else {
                    throw FrontendServiceError.localized(
                        L10n.text(
                            "error.no_session",
                            "The daemon did not identify exactly one session."
                        )
                    )
                }
                machineID = machine.id
                sessionID = session.id
                try await refreshNow()
                let updates = await service.updates()
                let resourceStream: FrontendResourceStream
                do {
                    resourceStream = try await openResourceStream(
                        service: service,
                        machineID: machine.id,
                        sessionID: session.id
                    )
                } catch {
                    await service.stopUpdates(generation: updates.generation)
                    throw error
                }
                beginResourceUpdates(
                    service: service,
                    initialUpdates: updates,
                    initialStream: resourceStream
                )
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
        let controllers = Array(terminalControllers.values)
        let titles = Array(terminalTitles.values)
        let retirements = Array(terminalRetirementTasks.values)
        let mutations = Array(mutationTasks.values)
        for mutation in mutations { mutation.cancel() }
        terminalControllers.removeAll()
        terminalTitles.removeAll()
        terminalRetirementTasks.removeAll()
        mutationTasks.removeAll()
        replaceableMutationIDs.removeAll()
        snapshot = nil
        resourceRevision = nil
        resourceState = nil
        resourceGeneration.advance()
        machineID = nil
        sessionID = nil
        focusMutations = FocusMutationTracker()
        let owned = service
        service = nil
        for controller in controllers {
            await controller.shutdownAndWait()
        }
        for title in titles { title.cancel() }
        for retirement in retirements {
            await retirement.value
        }
        for mutation in mutations {
            await mutation.value
        }
        if let owned {
            await owned.shutdown()
        }
        isConnecting = false
        recordAndPresent(error)
    }

    private func recordAndPresent(_ error: any Error) {
        if let diagnostic = (error as? FrontendServiceError)?.diagnosticDescription,
           !diagnostic.isEmpty
        {
            transportDiagnostics = [transportDiagnostics, diagnostic]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        errorMessage = error.localizedDescription
    }

    private func openResourceStream(
        service: FrontendService,
        machineID: String,
        sessionID: String
    ) async throws -> FrontendResourceStream {
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
        return FrontendResourceStream(id: streamID)
    }

    private func cancelResourceStream(
        service: FrontendService,
        machineID: String,
        sessionID: String,
        stream: FrontendResourceStream
    ) async throws {
        try await service.requestDiscardingResult(
            "stream.cancel",
            params: stream.cancellationParameters(
                machineID: machineID,
                sessionID: sessionID
            )
        )
    }

    private func beginResourceUpdates(
        service: FrontendService,
        initialUpdates: FrontendUpdateSubscription,
        initialStream: FrontendResourceStream
    ) {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            var updates = initialUpdates
            var resourceStream = initialStream
            while !Task.isCancelled {
                var endReason = FrontendResourceStreamEndReason.none
                var recoveryNeeded = false
                for await _ in updates.stream {
                    guard !Task.isCancelled else { break }
                    guard let self else { continue }
                    let batch = await service.drainResourceUpdates()
                    if batch.overflowed {
                        recoveryNeeded = true
                        break
                    } else if !batch.envelopes.isEmpty {
                        let events = await self.resourceDecoder.decode(batch.envelopes)
                        if events == nil || self.applyResourceEvents(events ?? []) == false {
                            recoveryNeeded = true
                            break
                        }
                    }
                    if batch.ended {
                        endReason = batch.endReason
                        break
                    }
                }
                await service.stopUpdates(generation: updates.generation)
                guard !Task.isCancelled, let self else { return }
                guard recoveryNeeded || endReason == .gap else {
                    await self.disconnectAfterFailure(
                        FrontendServiceError.localized(L10n.text(
                            "error.session_event_stream_ended",
                            "The session event stream ended."
                        ))
                    )
                    return
                }
                do {
                    guard let machineID = self.machineID, let sessionID = self.sessionID else {
                        return
                    }
                    let recovered = try await self.recoverResourceStream(
                        service: service,
                        machineID: machineID,
                        sessionID: sessionID,
                        currentStream: resourceStream
                    )
                    updates = recovered.updates
                    resourceStream = recovered.stream
                } catch {
                    await self.disconnectAfterFailure(error)
                    return
                }
            }
        }
    }

    private func recoverResourceStream(
        service: FrontendService,
        machineID: String,
        sessionID: String,
        currentStream: FrontendResourceStream
    ) async throws -> (updates: FrontendUpdateSubscription, stream: FrontendResourceStream) {
        try await cancelResourceStream(
            service: service,
            machineID: machineID,
            sessionID: sessionID,
            stream: currentStream
        )
        let pendingRefresh = refreshTask
        pendingRefresh?.cancel()
        await pendingRefresh?.value
        await service.discardResourceUpdates()

        let attempts = max(1, recoveryPolicy.maximumAttempts)
        var lastError: (any Error)?
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do {
                try await refreshNow()
                let nextUpdates = await service.updates()
                do {
                    let nextStream = try await openResourceStream(
                        service: service,
                        machineID: machineID,
                        sessionID: sessionID
                    )
                    return (nextUpdates, nextStream)
                } catch {
                    await service.stopUpdates(generation: nextUpdates.generation)
                    throw error
                }
            } catch {
                lastError = error
            }
            if attempt + 1 < attempts {
                try await recoveryDelay(
                    recoveryPolicy.backoffNanoseconds(afterFailedAttempt: attempt)
                )
            }
        }
        throw lastError ?? FrontendServiceError.localized(L10n.text(
            "error.session_event_stream_ended",
            "The session event stream ended."
        ))
    }

    private func applyResourceEvents(_ events: [FrontendResourceEvent]) -> Bool {
        guard !events.isEmpty else { return true }
        var nextState = resourceState ?? snapshot
        var nextRevision = resourceRevision
        var impact: FrontendResourceImpact = []
        var terminalTitlesByID: [String: String] = [:]

        for event in events {
            switch event {
            case .snapshot(let next):
                nextState = next
                nextRevision = next.cursor.revision
                impact.formUnion([
                    .presentation, .selection, .terminalTitles, .terminalControllers,
                ])
                terminalTitlesByID.removeAll()

            case .delta(let delta):
                guard delta.revision != delta.previousRevision,
                      nextRevision == delta.previousRevision,
                      var next = nextState else { return false }
                for change in delta.changes {
                    guard let application = next.apply(change) else { return false }
                    switch application {
                    case .ignored:
                        break
                    case .changed(let changed):
                        impact.formUnion(changed)
                    case .terminalTitle(let id, let title):
                        terminalTitlesByID[id] = title
                    }
                }
                next.setRevision(delta.revision)
                nextState = next
                nextRevision = delta.revision
            }
        }

        guard let nextState, let nextRevision else { return false }
        resourceGeneration.advance()
        resourceState = nextState
        resourceRevision = nextRevision
        if impact.contains(.presentation) {
            snapshot = nextState
            if impact.contains(.selection) { reconcileSelection(nextState) }
            if impact.contains(.terminalTitles) { reconcileTerminalTitles(nextState) }
            if impact.contains(.terminalControllers) { reconcileTerminalControllers(nextState) }
        }
        if !impact.contains(.terminalTitles) {
            for (id, title) in terminalTitlesByID {
                guard let owner = terminalTitles[id] else { return false }
                owner.submit(title)
            }
        }
        return true
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            defer { self?.refreshTask = nil }
            guard let self, !Task.isCancelled else { return }
            do {
                try await refreshNow()
            } catch {
                recordAndPresent(error)
            }
        }
    }

    private func refreshNow() async throws {
        guard let service, let machineID, let sessionID else { return }
        let generation = resourceGeneration.token
        let next = try await fetchSnapshot(
            service: service,
            machineID: machineID,
            sessionID: sessionID
        )
        guard resourceGeneration.matches(generation) else { return }
        applySnapshot(next)
    }

    private func applySnapshot(_ next: ResourceSnapshot) {
        resourceGeneration.advance()
        resourceState = next
        snapshot = next
        resourceRevision = next.cursor.revision
        reconcileSelection(next)
        reconcileTerminalTitles(next)
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
        let placements: [String: String] = {
            guard let workspaceID = selectedWorkspaceID,
                  let screenID = selectedScreenID,
                  let screen = next.screens.first(where: {
                      $0.id == screenID && $0.workspaceID == workspaceID
                  }) else { return [] }
            return next.visibleTerminalPlacements(in: screen)
        }()
        let removed = terminalControllers.compactMap { paneID, controller in
            placements[paneID] == controller.terminalID ? nil : paneID
        }
        for paneID in removed {
            guard let controller = terminalControllers.removeValue(forKey: paneID) else { continue }
            retireTerminalController(controller)
        }
        guard let service else { return }
        for (paneID, terminalID) in placements {
            guard terminalControllers[paneID] == nil else { continue }
            let controller = NativeTerminalModel(
                terminalID: terminalID,
                service: service,
                runtime: ghosttyRuntime
            )
            terminalControllers[paneID] = controller
            controller.attach()
        }
    }

    private func reconcileTerminalTitles(_ next: ResourceSnapshot) {
        let live = Set(next.terminals.map(\.id))
        for id in Array(terminalTitles.keys) where !live.contains(id) {
            terminalTitles.removeValue(forKey: id)?.cancel()
        }
        for terminal in next.terminals {
            if let owner = terminalTitles[terminal.id] {
                owner.replace(with: terminal.title)
            } else {
                terminalTitles[terminal.id] = TerminalTitleOwner(
                    terminalID: terminal.id,
                    title: terminal.title
                )
            }
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

    func terminalTitleLookup() -> TerminalTitleFn {
        TerminalTitleFn(owners: terminalTitles)
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
        let enqueued = mutate(
            operation,
            selectors: selectors,
            onSuccess: { await self.reconcileFocusMutation(requestID) },
            onIndeterminate: { _ = self.focusMutations.finish(requestID) },
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
        if !enqueued, let rollback = focusMutations.rollback(requestID) {
            selectedWorkspaceID = rollback.workspaceID
            selectedScreenID = rollback.screenID
            if let snapshot { reconcileTerminalControllers(snapshot) }
        }
    }

    private func reconcileFocusMutation(_ requestID: UInt64) async {
        guard focusMutations.owns(requestID),
              let service,
              let machineID,
              let sessionID else { return }
        let generation = resourceGeneration.token
        do {
            let next = try await fetchSnapshot(
                service: service,
                machineID: machineID,
                sessionID: sessionID
            )
            guard focusMutations.owns(requestID) else { return }
            guard resourceGeneration.matches(generation) else {
                _ = focusMutations.finish(requestID)
                return
            }
            selectedWorkspaceID = next.workspaces.first { $0.focused }?.id
                ?? next.workspaces.first?.id
            if let selectedWorkspaceID {
                let screens = next.screens(in: selectedWorkspaceID)
                selectedScreenID = screens.first { $0.focused }?.id ?? screens.first?.id
            } else {
                selectedScreenID = nil
            }
            _ = focusMutations.finish(requestID)
            applySnapshot(next)
        } catch {
            guard focusMutations.finish(requestID) else { return }
            recordAndPresent(error)
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

    @discardableResult
    private func mutate(
        _ operation: String,
        selectors: [String: String],
        fields: [String: JSONValue] = [:],
        onSuccess: (() async -> Void)? = nil,
        onIndeterminate: (() -> Void)? = nil,
        onFailure: (() -> Bool)? = nil
    ) -> Bool {
        guard let service, let machineID, let sessionID else { return false }
        var params: [String: JSONValue] = [
            "machine": .string(machineID),
            "session": .string(sessionID),
        ]
        for (key, value) in selectors { params[key] = .string(value) }
        for (key, value) in fields { params[key] = value }

        let replacementKey = mutationReplacementKey(operation, selectors: selectors)
        guard mutationTasks.count < Self.maximumPendingMutations else {
            errorMessage = L10n.text(
                "error.too_many_changes",
                "Too many changes are waiting. Try again after they finish."
            )
            return false
        }
        if let replacementKey,
           let replacedID = replaceableMutationIDs[replacementKey],
           let replaced = mutationTasks[replacedID] {
            replaceableMutationIDs[replacementKey] = nil
            replaced.cancel()
        }

        let mutationID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { finishMutation(mutationID, replacementKey: replacementKey) }
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
            } catch is CancellationError {
                return
            } catch {
                if let serviceError = error as? FrontendServiceError,
                   serviceError.requiresAuthoritativeReconciliation {
                    onIndeterminate?()
                    scheduleRefresh()
                    recordAndPresent(serviceError)
                    return
                }
                if onFailure?() ?? true {
                    recordAndPresent(error)
                }
            }
        }
        mutationTasks[mutationID] = task
        if let replacementKey { replaceableMutationIDs[replacementKey] = mutationID }
        return true
    }

    private func mutationReplacementKey(
        _ operation: String,
        selectors: [String: String]
    ) -> String? {
        switch operation {
        case "workspace.focus", "screen.focus", "pane.focus", "tab.focus":
            return "focus"
        case "pane.split_ratio.set", "pane.viewport_width.set":
            return selectors["pane"].map { "\(operation):\($0)" }
        default:
            return nil
        }
    }

    private func finishMutation(_ id: UUID, replacementKey: String?) {
        mutationTasks[id] = nil
        if let replacementKey, replaceableMutationIDs[replacementKey] == id {
            replaceableMutationIDs[replacementKey] = nil
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
        focusMutations = FocusMutationTracker()
        let controllers = Array(terminalControllers.values)
        let titles = Array(terminalTitles.values)
        let retirements = Array(terminalRetirementTasks.values)
        let mutations = Array(mutationTasks.values)
        for mutation in mutations { mutation.cancel() }
        terminalControllers.removeAll()
        terminalTitles.removeAll()
        terminalRetirementTasks.removeAll()
        mutationTasks.removeAll()
        replaceableMutationIDs.removeAll()
        let ownedService = service
        service = nil
        snapshot = nil
        resourceRevision = nil
        resourceState = nil
        resourceGeneration.advance()
        for controller in controllers {
            await controller.shutdownAndWait()
        }
        for title in titles { title.cancel() }
        for retirement in retirements {
            await retirement.value
        }
        for mutation in mutations {
            await mutation.value
        }
        await ownedService?.shutdown()
    }
}
