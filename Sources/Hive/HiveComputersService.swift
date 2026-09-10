import CMUXMobileCore
import CmuxAuthRuntime
import CmuxHive
import CmuxSettingsUI
import Foundation
import Observation

@MainActor
final class HiveComputersService {
    static let shared = HiveComputersService()
    static let didChangeNotification = Notification.Name("cmux.computers.pairingsDidChange")

    private var controller: HivePairingController?
    private var auth: AuthCoordinator?
    private var identity: AuthenticatedSessionIdentity?
    private var teamID: String?
    private var loadTask: Task<Void, Never>?
    private var directoryObserver: NSObjectProtocol?
    private var catalogObserver: NSObjectProtocol?
    private var lastSnapshot: ComputersSettingsSnapshot?
    private var error: String?
    private var continuations: [UUID: AsyncStream<ComputersSettingsSnapshot>.Continuation] = [:]

    var pairedComputers: [HivePairedComputer] { controller?.computers ?? [] }

    func configure(auth: AuthCoordinator) {
        self.auth = auth
        if let directoryObserver { NotificationCenter.default.removeObserver(directoryObserver) }
        directoryObserver = NotificationCenter.default.addObserver(
            forName: DeviceDirectory.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        if let catalogObserver { NotificationCenter.default.removeObserver(catalogObserver) }
        catalogObserver = NotificationCenter.default.addObserver(
            forName: SurfaceCatalog.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        observeAccount()
    }

    func isPaired(_ instance: SurfaceDeviceInstanceID) -> Bool {
        pairedComputers.contains { $0.deviceID == instance.deviceID && $0.instanceTag == instance.tag }
    }

    func authorization(
        for instance: SurfaceDeviceInstanceID, route: CmxAttachRoute
    ) -> CmxLegacyTailscaleAuthorizationEvidence? {
        pairedComputers.first { $0.deviceID == instance.deviceID && $0.instanceTag == instance.tag }?
            .authorization(for: route)
    }

    func updates() -> AsyncStream<ComputersSettingsSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ComputersSettingsSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let value = snapshot()
        lastSnapshot = value
        continuation.yield(value)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func refresh() async {
        await loadTask?.value
        do { try await controller?.load() } catch { self.error = Self.message(for: error) }
        await DeviceSurfaceProviderRegistry.shared.refresh(force: true)
        publish()
    }

    func pair(_ input: String) async -> String? {
        guard DevicesFeature.isEnabled else { return Self.disabledMessage }
        guard let controller else { return error ?? Self.signInMessage }
        do {
            _ = try await controller.pair(input)
            guard self.controller === controller else { return Self.signInMessage }
            error = nil
            publish()
            return nil
        } catch {
            guard self.controller === controller else { return Self.signInMessage }
            return Self.message(for: error)
        }
    }

    func unpair(_ id: String) async {
        guard let instance = SurfaceDeviceInstanceID(wireValue: id), let controller,
              let computer = pairedComputers.first(where: { $0.deviceID == instance.deviceID && $0.instanceTag == instance.tag }) else { return }
        do {
            try await controller.unpair(id: computer.id)
            guard self.controller === controller else { return }
            error = nil
        } catch {
            guard self.controller === controller else { return }
            self.error = Self.message(for: error)
        }
        publish()
    }

    func open(_ id: String) async {
        guard let instance = SurfaceDeviceInstanceID(wireValue: id), isPaired(instance) else { return }
        let scope = identity
        guard DevicesFeature.isEnabled else {
            error = Self.disabledMessage
            publish()
            return
        }
        if let provider = DeviceSurfaceProviderRegistry.shared.provider(for: instance) {
            await provider.refresh(force: true)
        }
        guard identity == scope, isPaired(instance) else { return }
        guard let result = AppDelegate.shared?.applyRightSidebarRemoteCommand(.setMode(.machines, focus: true)) else { return }
        switch result {
        case .failure(let message):
            error = message
        case .ok, .state:
            DeviceSurfaceProviderRegistry.shared.reveal(instance: instance)
            error = nil
        }
        publish()
    }

    private func observeAccount() {
        guard let auth else { return }
        let scope = withObservationTracking {
            (auth.authenticatedSessionIdentity, auth.resolvedTeamID)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAccount() }
        }
        guard scope.0 != identity || scope.1 != teamID else { return }
        identity = scope.0
        teamID = scope.1
        loadTask?.cancel()
        controller?.stop()
        controller = nil
        error = nil
        pairingsChanged()
        guard let identity = scope.0 else { return }
        let source = HiveAccountTokenSource(auth: auth, identity: identity, teamID: scope.1)
        #if DEBUG
        let allowsLoopback = true
        #else
        let allowsLoopback = false
        #endif
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.cmuxterm.app", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let runtime = HiveSyncRuntime(
                allowsLoopback: allowsLoopback,
                accessToken: { try await source.session().accessToken },
                cachedToken: { await source.cachedToken() },
                refreshToken: { try await source.refresh() }
            )
            let controller = try HivePairingController(
                databaseURL: directory.appendingPathComponent("paired-computers.sqlite3"), runtime: runtime,
                userID: identity.accountID, teamID: scope.1, email: auth.currentUser?.primaryEmail,
                ownDeviceID: MobileHostIdentity.deviceID(), ownInstanceTag: MobileHostIdentity.instanceTag(),
                allowsLoopback: allowsLoopback
            )
            self.controller = controller
            controller.onChange = { [weak self] in self?.pairingsChanged() }
            loadTask = Task { [weak self, weak controller] in
                guard let controller else { return }
                do { try await controller.load() } catch {
                    guard !Task.isCancelled, self?.controller === controller else { return }
                    self?.error = Self.message(for: error)
                    self?.publish()
                }
            }
        } catch {
            self.error = Self.message(for: HivePairingError.storageFailed)
            publish()
        }
    }

    private func snapshot() -> ComputersSettingsSnapshot {
        let directory = DeviceSurfaceProviderRegistry.shared.directory
        let paired = pairedComputers
        let pairedInstances = Set(paired.map {
            SurfaceDeviceInstanceID(deviceID: $0.deviceID, tag: $0.instanceTag)
        })
        var computers = (directory?.records ?? []).map { record in
            ComputersSettingsSnapshot.Computer(
                id: record.instance.wireValue, title: record.deviceName,
                tag: record.instance.isDefaultTag ? nil : record.instance.tag,
                isPaired: pairedInstances.contains(record.instance),
                isOnline: DeviceSurfaceProviderRegistry.shared.provider(for: record.instance)?.link.isConnected == true
                    ? true : (directory?.presenceState == .live ? record.isOnline : nil)
            )
        }
        let existing = Set(computers.map(\.id))
        for paired in paired {
            let instance = SurfaceDeviceInstanceID(deviceID: paired.deviceID, tag: paired.instanceTag)
            guard !existing.contains(instance.wireValue) else { continue }
            computers.append(.init(
                id: instance.wireValue, title: paired.displayName, tag: instance.isDefaultTag ? nil : instance.tag,
                isPaired: true, isOnline: nil
            ))
        }
        return ComputersSettingsSnapshot(
            computers: computers.sorted {
                let order = $0.title.localizedStandardCompare($1.title)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            },
            isSignedIn: identity != nil, error: error ?? directory?.registryError
        )
    }

    private func pairingsChanged() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        publish()
    }

    private func publish() {
        let value = snapshot()
        guard value != lastSnapshot else { return }
        lastSnapshot = value
        for continuation in continuations.values { continuation.yield(value) }
    }

    private static var signInMessage: String {
        String(localized: "settings.computers.signIn", defaultValue: "Sign in to the same account on both Macs to pair them.")
    }

    private static var disabledMessage: String {
        String(localized: "settings.computers.enableDevices", defaultValue: "Enable Devices in Beta Features to connect to your other Macs.")
    }

    private static func message(for error: any Error) -> String {
        switch error as? HivePairingError {
        case .invalidInput:
            String(localized: "settings.computers.invalidPairing", defaultValue: "Enter a pairing link or a numeric Tailscale IP and port.")
        case .accountMismatch:
            signInMessage
        case .tailscaleRequired:
            String(localized: "settings.computers.tailscaleRequired", defaultValue: "Use the other Mac’s pairing code with a numeric Tailscale IP address and port.")
        case .thisMac:
            String(localized: "settings.computers.selfPairing", defaultValue: "This code belongs to this Mac. Enter the other Mac’s pairing code.")
        case .missingIdentity, .identityMismatch:
            String(localized: "settings.computers.identityFailed", defaultValue: "The Mac’s authenticated identity could not be verified. Update cmux on both Macs and copy a fresh pairing code.")
        case .busy:
            String(localized: "settings.computers.pairingBusy", defaultValue: "Wait for the current pairing attempt to finish.")
        case .stopped:
            signInMessage
        case .storageFailed:
            String(localized: "settings.computers.storageFailed", defaultValue: "Your paired Macs could not be loaded. Check available disk space and restart cmux.")
        case nil:
            String(localized: "settings.computers.operationFailed", defaultValue: "The computer operation failed. Check that both Macs are signed in and connected to Tailscale, then try again.")
        }
    }
}
