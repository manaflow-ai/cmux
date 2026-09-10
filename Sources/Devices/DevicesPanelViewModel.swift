import Foundation
import Observation

/// Presence status and reveal requests for the Cloud sidebar's My Devices section.
/// The shared Cloud model owns the outline, catalog snapshot, and drag lifecycle.
@MainActor
@Observable
final class DevicesPanelViewModel {
    private(set) var presenceState: DeviceDirectory.PresenceState = .stopped
    private(set) var revealRequest: CloudTreeRevealRequest?
    private(set) var registryError: String?
    private(set) var hasLoadedDirectory = false
    private(set) var isRefreshing = false
    private let registry: DeviceSurfaceProviderRegistry?
    private let windowID: UUID?
    @ObservationIgnored private var directoryObserver: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?

    init(registry: DeviceSurfaceProviderRegistry? = nil, windowID: UUID? = nil) {
        self.registry = registry
        self.windowID = windowID
        directoryObserver = NotificationCenter.default.addObserver(
            forName: DeviceDirectory.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.readDirectory() }
        }
    }

    deinit {
        if let directoryObserver { NotificationCenter.default.removeObserver(directoryObserver) }
    }

    /// Devices the directory knows, whether or not their providers have
    /// published yet; drives the empty state and the control-bar summary.
    var knownDeviceCount: Int { registry?.directory?.records.count ?? 0 }
    var onlineDeviceCount: Int { registry?.directory?.records.filter(\.isOnline).count ?? 0 }

    func start() {
        registry?.evaluate()
        readDirectory()
        consumePendingReveal()
    }

    /// Settings › Computers "Open": expand and select the device's row.
    func consumePendingReveal() {
        guard let instance = registry?.takePendingReveal(windowID: windowID) else { return }
        revealRequest = .machine(.device(instance))
    }

    func needsPairing(_ machine: SurfaceMachineID) -> Bool {
        guard let instance = machine.deviceInstance, let provider = registry?.provider(for: instance) else { return false }
        return !provider.record.isPaired || provider.link.needsAuthorization
    }

    func readDirectory() {
        guard let directory = registry?.directory else {
            presenceState = .stopped
            registryError = nil
            hasLoadedDirectory = false
            return
        }
        presenceState = directory.presenceState
        registryError = directory.registryError
        hasLoadedDirectory = directory.hasLoadedRegistry || directory.presenceState == .live
    }

    /// The explicit Refresh verb: registry re-read plus every link's re-sync.
    func refresh() {
        guard refreshTask == nil else { return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.registry?.refresh(force: true)
            self.readDirectory()
            self.isRefreshing = false
            self.refreshTask = nil
        }
    }

    /// The control-bar status line for the presence connection.
    var statusText: String? {
        if registryError != nil, knownDeviceCount == 0 {
            return String(localized: "devices.status.registryUnreachable", defaultValue: "Device list unreachable \u{2014} retrying")
        }
        switch presenceState {
        case .stopped:
            return nil
        case .connecting:
            return String(localized: "devices.status.connecting", defaultValue: "Connecting to presence\u{2026}")
        case .live:
            return String(
                format: String(localized: "devices.status.live", defaultValue: "%1$d of %2$d online"),
                onlineDeviceCount, knownDeviceCount
            )
        case .retrying(let attempt, _):
            return String(
                format: String(localized: "devices.status.retrying", defaultValue: "Presence disconnected \u{2014} reconnecting (%d)"),
                attempt
            )
        }
    }

    var statusIsWarning: Bool {
        if registryError != nil, knownDeviceCount == 0 { return true }
        if case .retrying = presenceState { return true }
        return false
    }
}
