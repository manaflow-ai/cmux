import AppKit
import CmuxNextApps
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Synchronization

/// App platform in the App (plans/cmux-next/app-platform.md), DEV
/// prototype: the prototype registry, the JavaScriptCore app host with its
/// operation sink, and catalog event fan-out from the control snapshot.
/// The router-backed sink attaches when the control socket starts; calls
/// before that answer `unavailable`.
@MainActor
final class AppsService {
    unowned let services: AppServices
    let registry: AppRegistry
    let host: AppHost
    let storage: AppStorageStore
    private let sink = DeferredAppSink()
    private var fingerprints: [String: Int] = [:]

    init(services: AppServices) {
        self.services = services
        let directory = AppRegistryFile.appsDirectory(tag: services.environment.tag)
        registry = AppRegistry(directory: directory)
        storage = AppStorageStore(directory: directory.appending(path: "storage", directoryHint: .isDirectory))
        host = AppHost(sink: sink)
        host.grants = { [weak self] manifest in self?.grants(for: manifest) ?? [] }
    }

    func start() {
        // task-owner: one-shot registry scan at launch
        Task { await registry.load() }
    }

    /// Wires the sink to the control router (reads, action.run) and the daemon.
    func attach(router: ControlRouter) {
        let daemon = services.daemon
        let ledger: @Sendable () async throws -> [ListNotificationsRequest.Entry] = {
            guard let connection = await MainActor.run(body: { daemon.connection }) else {
                throw AppOperationError(code: "unavailable", message: "the daemon is not connected", retryable: true)
            }
            return try await connection.notificationLedger(limit: 200)
        }
        sink.attach(AppOperationRouter(router: router, storage: storage, ledger: ledger))
    }

    /// Prototype grants: the manifest's required scopes, for apps the
    /// registry lets run (first-party samples and `local/` apps only; the
    /// JSC engine has no OS sandbox). Optional scopes wait for consent UI.
    func grants(for manifest: AppManifest) -> Set<String> {
        guard registry.app(manifest.id)?.isActive == true || registry.app(manifest.id) == nil else { return [] }
        return Set(manifest.scopes.map(\.scope))
    }

    /// Posts `<family>.changed` for streams an app listens to, when the
    /// published mirror changed for that family.
    func topologyPublished(_ topology: ControlTopology) {
        let active = host.events.activeStreams
        guard !active.isEmpty else { return }
        for (stream, value) in AppTopologyReads.fingerprints(topology) where active.contains(stream) {
            if fingerprints[stream] != value {
                let first = fingerprints[stream] == nil
                fingerprints[stream] = value
                if !first { host.events.post(stream) }
            }
        }
    }
}

/// The sink the host holds from launch; the real one attaches when the
/// control router exists.
nonisolated final class DeferredAppSink: AppOperationSink, Sendable {
    private let inner = Mutex<(any AppOperationSink)?>(nil)

    func attach(_ sink: any AppOperationSink) { inner.withLock { $0 = sink } }

    func perform(_ request: AppOperationRequest) async -> Result<AppOperationResult, AppOperationError> {
        guard let sink = inner.withLock({ $0 }) else {
            return .failure(AppOperationError(code: "unavailable", message: "cmux is still starting", retryable: true))
        }
        return await sink.perform(request)
    }
}
