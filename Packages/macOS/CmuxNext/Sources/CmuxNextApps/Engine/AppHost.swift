public import Foundation
public import Observation

/// Runs installed apps on the prototype engine and owns their mounts
/// (app-platform.md section 4; temporary owner until the Rust app host
/// lands). Engines start on first use (activation) and stop when their
/// last mount goes away, so an app nobody shows costs no wakeups.
@MainActor
@Observable
public final class AppHost {
    public private(set) var logs: [String: [AppLogLine]] = [:]
    /// Why an app's engine stopped on its own (limit, load failure).
    public private(set) var failures: [String: String] = [:]
    @ObservationIgnored private(set) var engines: [String: AppEngine] = [:]
    @ObservationIgnored private var mounts: [String: AppMount] = [:]
    @ObservationIgnored private var starting: [String: Task<AppEngine?, Never>] = [:]
    @ObservationIgnored private var nextMount = 1
    @ObservationIgnored private var nextLog = 1
    @ObservationIgnored private let sink: any AppOperationSink
    @ObservationIgnored public let events: AppEventHub
    @ObservationIgnored private let clock: any AppEngineClock
    /// Granted scopes and settings per app (the registry supplies them).
    @ObservationIgnored public var grants: (AppManifest) -> Set<String> = { Set($0.scopes.map(\.scope)) }
    @ObservationIgnored public var settings: (AppManifest) -> AppJSON = { .object($0.contributes.settingsDefaults) }
    static let logLimit = 500

    public init(sink: any AppOperationSink, events: AppEventHub = AppEventHub(), clock: any AppEngineClock = ContinuousAppEngineClock()) {
        self.sink = sink
        self.events = events
        self.clock = clock
    }

    /// Mounts `contribution` of the app at `directory` and renders it.
    public func mount(_ manifest: AppManifest, directory: URL, contribution: AppContribution, surface: String) -> AppMount {
        let mount = AppMount(id: "m\(nextMount)", appID: manifest.id, contribution: contribution, bundleDirectory: directory, host: self)
        nextMount += 1
        mounts[mount.id] = mount
        guard let export = contribution.export else {
            mount.model.status = .failed("\(manifest.globalID(of: contribution)) has no render export")
            return mount
        }
        let context: AppJSON = ["contribution": .string(manifest.globalID(of: contribution)), "surface": .string(surface)]
        // task-owner: the first render; the mount's model reports the outcome
        Task {
            guard let engine = await engine(for: manifest, directory: directory) else {
                mount.model.status = .failed(failures[manifest.id] ?? "the app did not start")
                return
            }
            guard mounts[mount.id] != nil else { return }
            if let error = await engine.mount(mount.id, export: export, context: context) { mount.model.status = .failed(error) }
        }
        return mount
    }

    public func unmount(_ mount: AppMount) {
        guard mounts.removeValue(forKey: mount.id) != nil, let engine = engines[mount.appID] else { return }
        let appID = mount.appID
        let remaining = mounts.values.contains { $0.appID == appID }
        // task-owner: unmount (and the idle stop) ordered on the engine
        Task {
            await engine.unmount(mount.id)
            if !remaining { await self.stop(appID, reason: "idle") }
        }
    }

    /// Runs a command export (`contributes.commands[].run`).
    public func runCommand(_ manifest: AppManifest, directory: URL, export: String, arguments: AppJSON = .object([:])) async
        -> Result<AppJSON, AppOperationError> {
        guard let engine = await engine(for: manifest, directory: directory) else {
            return .failure(AppOperationError(code: "app.stopped", message: failures[manifest.id] ?? "the app did not start"))
        }
        return await engine.runCommand(export, arguments: arguments)
    }

    /// Stops the app's engine; its mounts show the reason until reloaded.
    public func stop(_ appID: String, reason: String = "stopped") async {
        starting[appID]?.cancel()
        starting.removeValue(forKey: appID)
        guard let engine = engines.removeValue(forKey: appID) else { return }
        await engine.stop(reason: reason)
    }

    /// Restarts the app and re-renders every mount it has.
    public func reload(_ manifest: AppManifest, directory: URL) async {
        await stop(manifest.id, reason: "reloading")
        failures.removeValue(forKey: manifest.id)
        for mount in mounts.values where mount.appID == manifest.id {
            mount.model.reset()
            guard let export = mount.contribution.export, let engine = await engine(for: manifest, directory: directory) else { continue }
            let context: AppJSON = ["contribution": .string(manifest.globalID(of: mount.contribution)), "surface": "sidebarSection"]
            if let error = await engine.mount(mount.id, export: export, context: context) { mount.model.status = .failed(error) }
        }
    }

    public func isRunning(_ appID: String) -> Bool { engines[appID] != nil }

    private func engine(for manifest: AppManifest, directory: URL) async -> AppEngine? {
        if let engine = engines[manifest.id] { return engine }
        if let pending = starting[manifest.id] { return await pending.value }
        let appID = manifest.id
        let configuration = AppEngineConfiguration(
            manifest: manifest, bundleDirectory: directory, grantedScopes: grants(manifest), settings: settings(manifest), sink: sink,
            events: events, clock: clock) { [weak self] output in
                // task-owner: engine output, in order, to the main actor
                Task { @MainActor in self?.handle(appID, output) }
            }
        let task = Task { () -> AppEngine? in
            let engine = AppEngine(configuration: configuration)
            do {
                try await engine.start()
                return engine
            } catch {
                self.failures[appID] = (error as? AppEngineError)?.message ?? String(describing: error)
                return nil
            }
        }
        starting[appID] = task
        let engine = await task.value
        starting.removeValue(forKey: appID)
        if let engine { engines[appID] = engine }
        return engine
    }

    private func handle(_ appID: String, _ output: AppEngineOutput) {
        switch output {
        case let .scene(mount, ops):
            mounts[mount]?.model.apply(ops)
        case let .log(level, message):
            append(appID, level: level, message: message)
        case let .stopped(reason):
            append(appID, level: reason == "idle" || reason == "reloading" || reason == "stopped" ? "info" : "error", message: "stopped: \(reason)")
            guard reason != "idle", reason != "reloading", reason != "stopped" else { return }
            failures[appID] = reason
            engines.removeValue(forKey: appID)
            for mount in mounts.values where mount.appID == appID { mount.model.status = .failed(reason) }
        }
    }

    private func append(_ appID: String, level: String, message: String) {
        var lines = logs[appID] ?? []
        lines.append(AppLogLine(id: nextLog, date: Date(), level: level, message: message))
        nextLog += 1
        if lines.count > Self.logLimit { lines.removeFirst(lines.count - Self.logLimit) }
        logs[appID] = lines
    }
}
