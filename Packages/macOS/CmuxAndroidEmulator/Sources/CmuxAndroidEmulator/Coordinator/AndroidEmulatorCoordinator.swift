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
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Creates a coordinator for an injected Android emulator service.
    ///
    /// - Parameter service: The service used for discovery and lifecycle actions.
    public init(service: any AndroidEmulatorServicing) {
        self.service = service
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
            launchingAVDNames.subtract(runningNames)
            if let connectedEmulatorSerials = snapshot.connectedEmulatorSerials {
                stoppingSerials.formIntersection(connectedEmulatorSerials)
            }
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
        launchingAVDNames.remove(avdName)
    }

    /// Stops a running emulator and refreshes its Android Debug Bridge state.
    ///
    /// - Parameters:
    ///   - avdName: The selected AVD name used to revalidate the reusable emulator serial.
    ///   - serial: The selected emulator's validated Android Debug Bridge serial.
    ///   - transportID: The non-reusable transport identity captured with the selected row.
    public func stop(avdName: String, serial: String, transportID: String) async {
        guard !stoppingSerials.contains(serial) else { return }
        actionError = nil
        stoppingSerials.insert(serial)
        do {
            try await service.stop(avdName: avdName, serial: serial, transportID: transportID)
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
        stoppingSerials.remove(serial)
    }

    /// Routes an emulator control through the same transport validation used by lifecycle actions.
    public func perform(
        _ action: AndroidEmulatorControlAction,
        avdName: String,
        serial: String,
        transportID: String
    ) async {
        actionError = nil
        do {
            try await service.perform(
                action,
                avdName: avdName,
                serial: serial,
                transportID: transportID
            )
        } catch let error as AndroidEmulatorError {
            actionError = error
        } catch {
            actionError = .commandFailed(tool: "adb", detail: String(describing: error))
        }
    }

    /// Returns the current primary display dimensions for an authoritative running row.
    public func displaySize(
        avdName: String,
        serial: String,
        transportID: String
    ) async -> AndroidEmulatorDisplaySize? {
        do {
            return try await service.displaySize(
                avdName: avdName,
                serial: serial,
                transportID: transportID
            )
        } catch let error as AndroidEmulatorError {
            actionError = error
        } catch {
            actionError = .commandFailed(tool: "adb", detail: String(describing: error))
        }
        return nil
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
