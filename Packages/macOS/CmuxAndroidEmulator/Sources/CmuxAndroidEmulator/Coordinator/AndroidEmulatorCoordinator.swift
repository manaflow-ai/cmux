public import Observation

/// Main-actor Android emulator state and user-action coordinator.
@MainActor @Observable
public final class AndroidEmulatorCoordinator {
    /// Current SDK and AVD loading state.
    public private(set) var loadState: AndroidEmulatorLoadState = .idle

    /// AVD names whose vendor process has been spawned but is not yet visible to `adb`.
    public private(set) var launchingAVDNames: Set<String> = []

    /// Emulator serials for which a stop command is in flight or awaiting refresh.
    public private(set) var stoppingSerials: Set<String> = []

    /// Most recent action failure, kept separate from the last successful snapshot.
    public private(set) var actionError: AndroidEmulatorError?

    /// Whether a snapshot refresh is currently running.
    public private(set) var isRefreshing = false

    private let service: any AndroidEmulatorServicing
    private let actionConfirmationTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Creates a coordinator for an injected Android emulator service.
    ///
    /// - Parameter service: The service used for discovery and lifecycle actions.
    public init(service: any AndroidEmulatorServicing) {
        self.service = service
        self.actionConfirmationTimeout = .seconds(30)
        self.sleep = { duration in
            // This is the cancellable deadline for surfacing an unconfirmed lifecycle action.
            try await Task.sleep(for: duration)
        }
    }

    init(
        service: any AndroidEmulatorServicing,
        actionConfirmationTimeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.service = service
        self.actionConfirmationTimeout = actionConfirmationTimeout
        self.sleep = sleep
    }

    /// Refreshes the selected SDK, installed AVDs, and running state.
    public func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performRefresh()
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh() async {
        isRefreshing = true
        if case .loaded = loadState {
            // Preserve the last useful list while the toolbar shows refresh progress.
        } else {
            loadState = .loading
        }
        defer { isRefreshing = false }

        do {
            let snapshot = try await service.snapshot()
            let runningNames = Set(snapshot.devices.filter(\.state.isRunning).map(\.name))
            let runningSerials = Set(snapshot.devices.compactMap(\.state.serial))
            launchingAVDNames.subtract(runningNames)
            stoppingSerials.formIntersection(runningSerials)
            loadState = .loaded(snapshot)
        } catch let error as AndroidEmulatorError {
            loadState = .failed(error)
        } catch {
            loadState = .failed(.commandFailed(tool: "Android SDK", detail: String(describing: error)))
        }
    }

    /// Launches an AVD in the vendor emulator window.
    ///
    /// - Parameter avdName: The installed AVD name selected by the user.
    public func launch(avdName: String) async {
        guard !launchingAVDNames.contains(avdName) else { return }
        actionError = nil
        launchingAVDNames.insert(avdName)
        do {
            try await service.launch(avdName: avdName)
        } catch let error as AndroidEmulatorError {
            launchingAVDNames.remove(avdName)
            actionError = error
            return
        } catch {
            launchingAVDNames.remove(avdName)
            actionError = .launchFailed(detail: String(describing: error))
            return
        }

        await refreshAfterPendingAction()
        guard launchingAVDNames.contains(avdName) else { return }
        do {
            try await sleep(actionConfirmationTimeout)
        } catch {
            launchingAVDNames.remove(avdName)
            return
        }
        if launchingAVDNames.remove(avdName) != nil {
            actionError = .launchNotConfirmed(name: avdName)
        }
    }

    /// Stops a running emulator and refreshes its Android Debug Bridge state.
    ///
    /// - Parameter serial: The selected emulator's validated Android Debug Bridge serial.
    public func stop(serial: String) async {
        guard !stoppingSerials.contains(serial) else { return }
        actionError = nil
        stoppingSerials.insert(serial)
        do {
            try await service.stop(serial: serial)
        } catch let error as AndroidEmulatorError {
            stoppingSerials.remove(serial)
            actionError = error
            return
        } catch {
            stoppingSerials.remove(serial)
            actionError = .commandFailed(tool: "adb", detail: String(describing: error))
            return
        }

        await refreshAfterPendingAction()
        guard stoppingSerials.contains(serial) else { return }
        do {
            try await sleep(actionConfirmationTimeout)
        } catch {
            stoppingSerials.remove(serial)
            return
        }
        if stoppingSerials.remove(serial) != nil {
            actionError = .stopNotConfirmed(serial: serial)
        }
    }

    private func refreshAfterPendingAction() async {
        if let refreshTask {
            await refreshTask.value
        }
        await refresh()
    }

    /// Clears the currently displayed action failure.
    public func clearActionError() {
        actionError = nil
    }
}
