import Foundation

/// Host calls (`call`) and timers.
extension AppEngine {
    /// Host-provided ops the catalog does not own: no machine/session selectors.
    static let hostOpPrefixes = ["action.", "app.", "net.", "integration."]

    func nativeCall(_ name: String, params paramsText: String, options optionsText: String, callback: Int) {
        guard let params = try? AppJSON.parse(paramsText), let options = try? AppJSON.parse(optionsText) else {
            return answer(callback, .failure(AppOperationError(code: "invalid_params", message: "params are not JSON")))
        }
        let grants = configuration.grants.snapshot
        if let refusal = configuration.scopes.refusal(op: name, params: params, granted: grants.scopes, sandboxed: grants.sandboxed) {
            return answer(callback, .failure(refusal))
        }
        guard pendingCalls.count < configuration.maxPendingCalls else {
            return answer(callback, .failure(AppOperationError(code: "app.limit", message: "more than \(configuration.maxPendingCalls) pending calls",
                                                               details: ["limit": "pendingCalls"])))
        }
        let request = makeRequest(name, params: params, options: options)
        let sink = configuration.sink
        pendingCalls[callback] = Task { [weak self] in
            let result = await sink.perform(request)
            await self?.finish(callback, result)
        }
    }

    func makeRequest(_ name: String, params: AppJSON, options: AppJSON) -> AppOperationRequest {
        var params = params
        if !Self.hostOpPrefixes.contains(where: name.hasPrefix), case .object(var object) = params {
            for key in ["machine", "session"] where object[key] == nil { object[key] = "current" }
            params = .object(object)
        }
        var key = options["idempotencyKey"]?.stringValue
        if key == nil, configuration.scopes.isMutation(name) { key = UUID().uuidString.lowercased() }
        return AppOperationRequest(app: configuration.manifest.id, appVersion: configuration.manifest.version, op: name, params: params,
                                   options: options, origin: acceptGesture(options["gesture"]?.stringValue, consume: configuration.scopes.isMutation(name)) ? .user : .script,
                                   idempotencyKey: key)
    }

    private func finish(_ callback: Int, _ result: Result<AppOperationResult, AppOperationError>) {
        guard pendingCalls.removeValue(forKey: callback) != nil else { return }
        resolve(callback, result)
    }

    /// Answers a refused call on a later turn (the runtime expects the
    /// promise to settle asynchronously, like any host call).
    private func answer(_ callback: Int, _ result: Result<AppOperationResult, AppOperationError>) {
        // task-owner: one deferred refusal on the engine executor
        Task { [weak self] in await self?.resolve(callback, result) }
    }

    private func resolve(_ callback: Int, _ result: Result<AppOperationResult, AppOperationError>) {
        guard state == .running else { return }
        switch result {
        case .success(let value): _ = enter("__cmuxAppResolve", [callback, true, value.json.jsonText])
        case .failure(let error): _ = enter("__cmuxAppResolve", [callback, false, error.json.jsonText])
        }
    }

    // MARK: Timers

    func nativeTimer(ms: Double, repeats: Bool) -> Int {
        guard timers.count < configuration.maxTimers else {
            configuration.output(.log(level: "error", message: "app.limit: more than \(configuration.maxTimers) timers"))
            return 0
        }
        let id = nextTimer
        nextTimer += 1
        let delay = max(0, Int(ms.isFinite ? ms : 0))
        timers[id] = (repeats, delay, schedule(id, ms: delay))
        return id
    }

    func nativeClearTimer(_ id: Int) {
        timers.removeValue(forKey: id)?.task.cancel()
    }

    private func schedule(_ id: Int, ms: Int) -> Task<Void, Never> {
        let clock = configuration.clock
        return Task { [weak self] in
            // wakeup-allow: one-shot app timer firing, cancelled by clearTimer, unmount and stop
            do { try await clock.delay(for: .milliseconds(ms)) } catch { return }
            await self?.fire(id)
        }
    }

    private func fire(_ id: Int) {
        guard state == .running, let timer = timers[id] else { return }
        if timer.repeats {
            timers[id] = (true, timer.ms, schedule(id, ms: timer.ms))
        } else {
            timers.removeValue(forKey: id)
        }
        _ = enter("__cmuxAppTimer", [id])
    }

    /// Diagnostics for the Installed tab and tests.
    public var counts: (pendingCalls: Int, timers: Int, subscriptions: Int) { (pendingCalls.count, timers.count, subscriptions.count) }
}
