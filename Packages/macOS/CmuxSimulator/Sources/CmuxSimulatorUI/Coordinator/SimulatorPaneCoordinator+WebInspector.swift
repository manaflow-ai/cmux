import CmuxSimulator

extension SimulatorPaneCoordinator {
    /// Opens a byte-bounded worker event stream for native inspector clients.
    /// Raw JSON arrives as `webInspectorMessage` chunks; lifecycle and failure
    /// events remain present so a client can terminate its own session exactly.
    public func subscribeWebInspectorSessionEvents() async -> SimulatorWorkerEventStream {
        await client.subscribe()
    }

    /// Refreshes inspectable pages for the selected Simulator.
    @discardableResult
    public func refreshWebInspectorTargets() async -> [SimulatorWebInspectorTarget] {
        (try? await refreshWebInspectorTargetsResult()) ?? webInspectorTargets
    }

    /// Refreshes targets and propagates the correlated worker failure.
    public func refreshWebInspectorTargetsResult() async throws -> [SimulatorWebInspectorTarget] {
        guard let deviceID = selectedDeviceID else { return [] }
        guard case let .webInspectorTargets(targets) = try await perform(
            .refreshWebInspectorTargets(deviceID: deviceID)
        ) else { return webInspectorTargets }
        return targets
    }

    /// Attaches the raw inspector stream to one page.
    @discardableResult
    public func attachWebInspector(
        targetID: String
    ) async -> SimulatorWebInspectorSessionStatus? {
        try? await attachWebInspectorResult(targetID: targetID)
    }

    /// Attaches a target and propagates the correlated worker failure.
    public func attachWebInspectorResult(
        targetID: String
    ) async throws -> SimulatorWebInspectorSessionStatus {
        guard case let .webInspectorSession(status) = try await perform(
            .attachWebInspector(targetID: targetID)
        ) else { return .detached }
        return status
    }

    /// Releases the selected page for other inspector clients.
    @discardableResult
    public func releaseWebInspector() async -> Bool {
        (try? await releaseWebInspectorResult()) == true
    }

    /// Releases the current target and propagates the correlated worker failure.
    public func releaseWebInspectorResult() async throws -> Bool {
        var highlightFailure: Error?
        if webInspectorIsHighlighted {
            do {
                _ = try await perform(.setWebInspectorHighlight(enabled: false))
                webInspectorIsHighlighted = false
            } catch {
                highlightFailure = error
            }
        }
        guard case .webInspectorSession(.detached) = try await perform(.releaseWebInspector) else {
            return false
        }
        webInspectorIsHighlighted = false
        if let highlightFailure { throw highlightFailure }
        return true
    }

    /// Highlights or unhighlights the attached page document.
    @discardableResult
    public func setWebInspectorHighlight(enabled: Bool) async -> Bool {
        (try? await setWebInspectorHighlightResult(enabled: enabled)) == true
    }

    /// Updates page highlighting and propagates the correlated worker failure.
    public func setWebInspectorHighlightResult(enabled: Bool) async throws -> Bool {
        _ = try await perform(.setWebInspectorHighlight(enabled: enabled))
        webInspectorIsHighlighted = enabled
        return true
    }

    /// Sends one raw JSON Web Inspector command.
    @discardableResult
    public func sendWebInspectorMessage(_ json: String) async -> Bool {
        (try? await sendWebInspectorMessageResult(json)) == true
    }

    /// Waits until the worker accepts a raw command into its bounded router.
    public func sendWebInspectorMessageResult(_ json: String) async throws -> Bool {
        _ = try await perform(.sendWebInspectorMessage(json: json))
        return true
    }

    /// Clears only the native tools response history, preserving the session.
    public func clearWebInspectorResponses() {
        webInspectorResponseBuffer.reset()
        webInspectorResponses = []
    }
}
