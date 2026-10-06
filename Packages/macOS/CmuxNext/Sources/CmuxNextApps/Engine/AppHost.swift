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
    /// Grants and settings per app (the registry supplies them). Engines
    /// read their `AppGrants` per call; `refreshGrants` rewrites it.
    @ObservationIgnored public var grants: (AppManifest) -> AppGrants.Snapshot = {
        AppGrants.Snapshot(scopes: Set($0.scopes.map(\.scope)))
    }
    @ObservationIgnored private var grantBoxes: [String: AppGrants] = [:]
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

    /// Re-reads the app's grants (revoke, sandbox switch); the next call sees them.
    public func refreshGrants(_ manifest: AppManifest) {
        grantBoxes[manifest.id]?.update(grants(manifest))
    }

    private func grantBox(_ manifest: AppManifest) -> AppGrants {
        if let box = grantBoxes[manifest.id] {
            box.update(grants(manifest))
            return box
        }
        let box = AppGrants(grants(manifest))
        grantBoxes[manifest.id] = box
        return box
    }

    /// Why no app may run (an administrator turned apps off), or nil.
    /// Setting a reason stops every running app; its mounts show the reason.
    public var disabledReason: String? {
        didSet {
            if disabledReason == nil, let oldValue {
                // Lifted: the next open or command starts the app again.
                failures = failures.filter { $0.value != oldValue }
                return
            }
            guard let disabledReason, oldValue == nil else { return }
            // task-owner: stops each engine once; a later start is refused by engine(for:)
            Task {
                for appID in Array(engines.keys) + Array(starting.keys) where self.disabledReason != nil {
                    await stop(appID, reason: disabledReason)
                }
            }
        }
    }

    private func engine(for manifest: AppManifest, directory: URL) async -> AppEngine? {
        if let disabledReason {
            failures[manifest.id] = disabledReason
            return nil
        }
        if let engine = engines[manifest.id] { return engine }
        if let pending = starting[manifest.id] {
            let engine = await pending.value
            return disabledReason == nil ? engine : nil
        }
        let appID = manifest.id
        let configuration = AppEngineConfiguration(
            manifest: manifest, bundleDirectory: directory, grants: grantBox(manifest), settings: settings(manifest), sink: sink,
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
                // A start cancelled by stop() records no failure of its own.
                if !Task.isCancelled { self.failures[appID] = (error as? AppEngineError)?.message ?? String(describing: error) }
                return nil
            }
        }
        starting[appID] = task
        let engine = await task.value
        // A start that was cancelled (stop) or overtaken by a policy that
        // turned apps off does not keep running.
        let current = starting[appID] == task
        if current { starting.removeValue(forKey: appID) }
        guard let engine else { return nil }
        if let disabledReason {
            failures[appID] = disabledReason
            await engine.stop(reason: disabledReason)
            return nil
        }
        guard current else {
            await engine.stop(reason: "stopped")
            return engines[appID]
        }
        engines[appID] = engine
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
