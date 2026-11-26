import CmuxSimulator
import Foundation

extension SimulatorPaneCoordinator {
    /// Sets one fixed simulated location and ends any cmux-managed route session.
    public func setLocation(_ coordinate: SimulatorLocationCoordinate) async {
        await waitForLocationRouteTeardown()
        guard let deviceID = selectedDeviceID else { return }
        let completionTask = cancelLocationRouteCompletion()
        _ = await completionTask?.value
        guard (try? await perform(.setLocation(
            deviceID: deviceID,
            coordinate: coordinate
        ))) != nil else {
            resumeLocationRouteCompletion()
            return
        }
        clearLocationRouteSessionState()
    }

    /// Clears the active fixed location or route.
    public func clearLocation() async {
        await waitForLocationRouteTeardown()
        guard let deviceID = selectedDeviceID else { return }
        let completionTask = cancelLocationRouteCompletion()
        _ = await completionTask?.value
        guard (try? await perform(.clearLocation(deviceID: deviceID))) != nil else {
            resumeLocationRouteCompletion()
            return
        }
        clearLocationRouteSessionState()
    }

    /// Starts a simulated movement route.
    /// - Parameter route: The ordered waypoints and travel speed.
    public func startLocationRoute(_ route: SimulatorLocationRoute) async {
        await waitForLocationRouteTeardown()
        guard let deviceID = selectedDeviceID else { return }
        let selectionGeneration = selectionGeneration
        let completionTask = cancelLocationRouteCompletion()
        _ = await completionTask?.value
        guard (try? await perform(.startLocationRoute(
            deviceID: deviceID,
            route: route
        ))) != nil else {
            resumeLocationRouteCompletion()
            return
        }
        guard !Task.isCancelled, !closed,
              self.selectionGeneration == selectionGeneration,
              selectedDeviceID == deviceID else {
            _ = try? await client.perform(.stopLocationRoute(deviceID: deviceID))
            return
        }
        beginLocationRouteSession(deviceID: deviceID, route: route)
    }

    /// Pauses the active simulated route at its estimated current position.
    public func pauseLocationRoute() async {
        await waitForLocationRouteTeardown()
        guard let deviceID = selectedDeviceID,
              locationRouteDeviceID == deviceID,
              locationRouteIsActive,
              !locationRouteIsPaused else { return }
        suspendLocationRouteCompletion()
        let completionTask = cancelLocationRouteCompletion()
        _ = await completionTask?.value
        guard (try? await perform(.pauseLocationRoute(deviceID: deviceID))) != nil else {
            resumeLocationRouteCompletion()
            return
        }
        locationRouteIsPaused = true
    }

    /// Resumes the route last paused by cmux.
    public func resumeLocationRoute() async {
        await waitForLocationRouteTeardown()
        guard let deviceID = selectedDeviceID,
              locationRouteDeviceID == deviceID,
              locationRouteIsPaused,
              (try? await perform(.resumeLocationRoute(deviceID: deviceID))) != nil else { return }
        locationRouteIsActive = true
        locationRouteIsPaused = false
        resumeLocationRouteCompletion()
    }

    /// Stops a route and restores its first waypoint.
    public func stopLocationRoute() async {
        await waitForLocationRouteTeardown()
        guard let deviceID = selectedDeviceID else { return }
        let completionTask = cancelLocationRouteCompletion()
        _ = await completionTask?.value
        guard (try? await perform(.stopLocationRoute(deviceID: deviceID))) != nil else { return }
        clearLocationRouteSessionState()
    }

    @discardableResult
    func beginLocationRouteTeardown() -> Task<Void, Never>? {
        let previousTeardown = locationRouteTeardownTask
        let deviceID = locationRouteDeviceID
        let completionTask = cancelLocationRouteCompletion()
        guard deviceID != nil || completionTask != nil else { return previousTeardown }
        let client = client
        let teardown = Task { @MainActor [weak self] in
            _ = await previousTeardown?.value
            _ = await completionTask?.value
            guard let self, let deviceID else { return }
            var finalError: (any Error)?
            for _ in 0..<3 {
                do {
                    _ = try await client.perform(.stopLocationRoute(deviceID: deviceID))
                    if self.locationRouteDeviceID == deviceID {
                        self.clearLocationRouteSessionState()
                    }
                    return
                } catch {
                    finalError = error
                }
            }
            if let finalError {
                self.failure = simulatorPaneFailure(
                    from: finalError,
                    code: "location_route_teardown_failed"
                )
            }
        }
        locationRouteTeardownTask = teardown
        return teardown
    }

    private func waitForLocationRouteTeardown() async {
        _ = await locationRouteTeardownTask?.value
    }

    private func beginLocationRouteSession(
        deviceID: String,
        route: SimulatorLocationRoute
    ) {
        locationRouteDeviceID = deviceID
        locationRoute = route
        locationRouteRemainingDuration = route.loops ? nil : route.estimatedDuration
        locationRouteStartedAt = locationRouteRemainingDuration == nil ? nil : locationRouteNow()
        locationRouteIsActive = true
        locationRouteIsPaused = false
        scheduleLocationRouteCompletion()
    }

    private func suspendLocationRouteCompletion() {
        guard let startedAt = locationRouteStartedAt,
              let remainingDuration = locationRouteRemainingDuration else { return }
        let elapsed = max(0, locationRouteNow().timeIntervalSince(startedAt))
        locationRouteRemainingDuration = max(0, remainingDuration - elapsed)
        locationRouteStartedAt = nil
    }

    private func resumeLocationRouteCompletion() {
        guard locationRouteRemainingDuration != nil else { return }
        locationRouteStartedAt = locationRouteNow()
        scheduleLocationRouteCompletion()
    }

    private func scheduleLocationRouteCompletion() {
        guard let deviceID = locationRouteDeviceID,
              let duration = locationRouteRemainingDuration else { return }
        locationRouteGeneration &+= 1
        let generation = locationRouteGeneration
        let sleeper = locationRouteSleeper
        locationRouteCompletionTask = Task { @MainActor [weak self] in
            do {
                try await sleeper.sleep(for: .seconds(duration))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.locationRouteGeneration == generation,
                  self.locationRouteDeviceID == deviceID,
                  self.locationRouteIsActive,
                  !self.locationRouteIsPaused else { return }
            self.locationRouteRemainingDuration = 0
            self.locationRouteStartedAt = nil
            self.locationRouteIsActive = false
            self.locationRouteIsPaused = false
            self.locationRouteCompletionTask = nil
        }
    }

    @discardableResult
    private func cancelLocationRouteCompletion() -> Task<Void, Never>? {
        locationRouteGeneration &+= 1
        let task = locationRouteCompletionTask
        locationRouteCompletionTask = nil
        task?.cancel()
        return task
    }

    private func clearLocationRouteSessionState() {
        locationRouteDeviceID = nil
        locationRoute = nil
        locationRouteRemainingDuration = nil
        locationRouteStartedAt = nil
        locationRouteIsActive = false
        locationRouteIsPaused = false
    }
}
