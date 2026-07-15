import Foundation

extension SimulatorControlService {
    /// Sets one fixed simulated location.
    public func setLocation(deviceID: String, coordinate: SimulatorLocationCoordinate) async throws {
        try validate(coordinate)
        try await mutationGate.withLocks([.location(deviceIdentifier: deviceID)]) {
            try await setLocationExclusively(deviceID: deviceID, coordinate: coordinate)
        }
    }

    private func setLocationExclusively(
        deviceID: String,
        coordinate: SimulatorLocationCoordinate
    ) async throws {
        let previousRoute = activeLocationRoutes[deviceID]
        let token = beginLocationOperation(deviceID: deviceID)
        do {
            _ = try await output(arguments: [
                "simctl", "location", deviceID, "set", coordinateArgument(coordinate),
            ])
            try requireCurrentLocationOperation(deviceID: deviceID, token: token)
            activeLocationRoutes.removeValue(forKey: deviceID)
            locationRouteInitialCoordinates.removeValue(forKey: deviceID)
            finishLocationOperation(deviceID: deviceID, token: token)
        } catch {
            finishLocationOperation(deviceID: deviceID, token: token)
            restoreLocationLifecycle(deviceID: deviceID, state: previousRoute)
            throw error
        }
    }

    /// Clears a fixed location or running route.
    public func clearLocation(deviceID: String) async throws {
        try await mutationGate.withLocks([.location(deviceIdentifier: deviceID)]) {
            try await clearLocationExclusively(deviceID: deviceID)
        }
    }

    private func clearLocationExclusively(deviceID: String) async throws {
        let previousRoute = activeLocationRoutes[deviceID]
        let token = beginLocationOperation(deviceID: deviceID)
        do {
            _ = try await output(arguments: ["simctl", "location", deviceID, "clear"])
            try requireCurrentLocationOperation(deviceID: deviceID, token: token)
            activeLocationRoutes.removeValue(forKey: deviceID)
            locationRouteInitialCoordinates.removeValue(forKey: deviceID)
            finishLocationOperation(deviceID: deviceID, token: token)
        } catch {
            finishLocationOperation(deviceID: deviceID, token: token)
            restoreLocationLifecycle(deviceID: deviceID, state: previousRoute)
            throw error
        }
    }

    /// Starts a route interpolated by CoreSimulator.
    public func startLocationRoute(deviceID: String, route: SimulatorLocationRoute) async throws {
        try validate(route: route, deviceID: deviceID)
        guard let initialCoordinate = route.waypoints.first else { return }
        try await mutationGate.withLocks([.location(deviceIdentifier: deviceID)]) {
            try await startLocationRoute(
                deviceID: deviceID,
                route: route,
                initialCoordinate: initialCoordinate
            )
        }
    }

    private func startLocationRoute(
        deviceID: String,
        route: SimulatorLocationRoute,
        initialCoordinate: SimulatorLocationCoordinate
    ) async throws {
        let previousRoute = activeLocationRoutes[deviceID]
        let token = beginLocationOperation(deviceID: deviceID)
        do {
            try await runLocationRouteCommand(deviceID: deviceID, route: route)
        } catch {
            finishLocationOperation(deviceID: deviceID, token: token)
            restoreLocationLifecycle(deviceID: deviceID, state: previousRoute)
            throw error
        }
        try requireCurrentLocationOperation(deviceID: deviceID, token: token)
        locationRouteInitialCoordinates[deviceID] = initialCoordinate
        activeLocationRoutes[deviceID] = .running(route: route, startedAt: now())
        scheduleLocationLifecycle(deviceID: deviceID, route: route, token: token)
    }

    private func restoreLocationLifecycle(deviceID: String, state: ActiveLocationRoute?) {
        guard let state else { return }
        activeLocationRoutes[deviceID] = state
        guard case let .running(route, startedAt) = state else { return }
        let token = UUID()
        locationRouteTokens[deviceID] = token
        let elapsed = max(0, now().timeIntervalSince(startedAt))
        let duration = routeDuration(route).map { total in
            route.loops && total > 0
                ? max(0, total - elapsed.truncatingRemainder(dividingBy: total))
                : max(0, total - elapsed)
        }
        scheduleLocationLifecycle(deviceID: deviceID, route: route, token: token, durationOverride: duration)
    }

    private func runLocationRouteCommand(
        deviceID: String,
        route: SimulatorLocationRoute
    ) async throws {
        try validate(route: route, deviceID: deviceID)
        var arguments = [
            "simctl", "location", deviceID, "start", "--speed=\(route.speed)",
        ]
        if let distance = route.updateDistance {
            guard distance.isFinite, distance > 0 else {
                throw SimulatorControlError(
                    code: "invalid_location_route",
                    arguments: arguments,
                    message: String(
                        localized: "simulator.control.locationDistanceInvalid",
                        defaultValue: "Location route update distance must be positive."
                    )
                )
            }
            arguments.append("--distance=\(distance)")
        }
        if let interval = route.updateInterval {
            guard interval.isFinite, interval > 0 else {
                throw SimulatorControlError(
                    code: "invalid_location_route",
                    arguments: arguments,
                    message: String(
                        localized: "simulator.control.locationIntervalInvalid",
                        defaultValue: "Location route update interval must be positive."
                    )
                )
            }
            arguments.append("--interval=\(interval)")
        }
        arguments += commandWaypoints(for: route).map(coordinateArgument)
        _ = try await output(arguments: arguments)
    }

    /// Pauses a route at its estimated current coordinate.
    public func pauseLocationRoute(deviceID: String) async throws {
        try await mutationGate.withLocks([.location(deviceIdentifier: deviceID)]) {
            try await pauseLocationRouteExclusively(deviceID: deviceID)
        }
    }

    private func pauseLocationRouteExclusively(deviceID: String) async throws {
        guard case let .running(route, startedAt) = activeLocationRoutes[deviceID] else {
            throw SimulatorControlError(
                code: "location_route_not_running",
                arguments: ["simctl", "location", deviceID],
                message: String(
                    localized: "simulator.control.locationRouteNotRunning",
                    defaultValue: "cmux has no running location route for this device."
                )
            )
        }
        let elapsed = max(0, now().timeIntervalSince(startedAt))
        let pausedRoute = remainingRoute(route, after: elapsed)
        let coordinate = pausedRoute.waypoints[0]
        let token = beginLocationOperation(deviceID: deviceID)
        do {
            _ = try await output(arguments: ["simctl", "location", deviceID, "clear"])
        } catch {
            finishLocationOperation(deviceID: deviceID, token: token)
            restoreLocationLifecycle(
                deviceID: deviceID,
                state: .running(route: route, startedAt: startedAt)
            )
            throw error
        }
        activeLocationRoutes.removeValue(forKey: deviceID)
        do {
            _ = try await output(arguments: [
                "simctl", "location", deviceID, "set", coordinateArgument(coordinate),
            ])
        } catch {
            finishLocationOperation(deviceID: deviceID, token: token)
            throw error
        }
        try requireCurrentLocationOperation(deviceID: deviceID, token: token)
        activeLocationRoutes[deviceID] = .paused(route: pausedRoute)
    }

    /// Resumes a route previously paused by this service.
    public func resumeLocationRoute(deviceID: String) async throws {
        try await mutationGate.withLocks([.location(deviceIdentifier: deviceID)]) {
            try await resumeLocationRouteExclusively(deviceID: deviceID)
        }
    }

    private func resumeLocationRouteExclusively(deviceID: String) async throws {
        guard case let .paused(route) = activeLocationRoutes[deviceID] else {
            throw SimulatorControlError(
                code: "location_route_not_paused",
                arguments: ["simctl", "location", deviceID],
                message: String(
                    localized: "simulator.control.locationRouteNotPaused",
                    defaultValue: "cmux has no paused location route for this device."
                )
            )
        }
        let initialCoordinate = locationRouteInitialCoordinates[deviceID] ?? route.waypoints[0]
        if route.waypoints.count < 2 {
            activeLocationRoutes.removeValue(forKey: deviceID)
            locationRouteTokens.removeValue(forKey: deviceID)
            return
        }
        try await startLocationRoute(
            deviceID: deviceID,
            route: route,
            initialCoordinate: initialCoordinate
        )
    }

    /// Stops a route and restores the coordinate where that route began.
    public func stopLocationRoute(deviceID: String) async throws {
        try await mutationGate.withLocks([.location(deviceIdentifier: deviceID)]) {
            try await stopLocationRouteExclusively(deviceID: deviceID)
        }
    }

    private func stopLocationRouteExclusively(deviceID: String) async throws {
        guard let initialCoordinate = locationRouteInitialCoordinates[deviceID] else {
            try await clearLocationExclusively(deviceID: deviceID)
            return
        }
        let token = beginLocationOperation(deviceID: deviceID)
        activeLocationRoutes.removeValue(forKey: deviceID)
        do {
            _ = try await output(arguments: ["simctl", "location", deviceID, "clear"])
            _ = try await output(arguments: [
                "simctl", "location", deviceID, "set", coordinateArgument(initialCoordinate),
            ])
        } catch {
            finishLocationOperation(deviceID: deviceID, token: token)
            throw error
        }
        try requireCurrentLocationOperation(deviceID: deviceID, token: token)
        locationRouteInitialCoordinates.removeValue(forKey: deviceID)
        finishLocationOperation(deviceID: deviceID, token: token)
    }

    func validate(_ coordinate: SimulatorLocationCoordinate) throws {
        guard coordinate.latitude.isFinite,
              coordinate.longitude.isFinite,
              (-90...90).contains(coordinate.latitude),
              (-180...180).contains(coordinate.longitude) else {
            throw SimulatorControlError(
                code: "invalid_location",
                arguments: [],
                message: String(
                    localized: "simulator.control.locationCoordinateInvalid",
                    defaultValue: "Latitude must be from -90 through 90 and longitude from -180 through 180."
                )
            )
        }
    }

    func validate(route: SimulatorLocationRoute, deviceID: String) throws {
        guard route.waypoints.count >= 2, route.speed.isFinite, route.speed > 0 else {
            throw SimulatorControlError(
                code: "invalid_location_route",
                arguments: ["simctl", "location", deviceID, "start"],
                message: String(
                    localized: "simulator.control.locationRouteInvalid",
                    defaultValue: "A location route needs at least two waypoints and a positive speed."
                )
            )
        }
        try route.waypoints.forEach(validate)
    }

    func coordinateArgument(_ coordinate: SimulatorLocationCoordinate) -> String {
        "\(coordinate.latitude),\(coordinate.longitude)"
    }

    func remainingRoute(
        _ route: SimulatorLocationRoute,
        after elapsed: TimeInterval
    ) -> SimulatorLocationRoute {
        if route.loops { return remainingLoopingRoute(route, after: elapsed) }
        var remainingDistance = elapsed * route.speed
        let points = route.waypoints
        guard points.count >= 2, let finalPoint = points.last else { return route }
        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            let segmentDistance = distance(from: start, to: end)
            if remainingDistance < segmentDistance, segmentDistance > 0 {
                let progress = remainingDistance / segmentDistance
                let current = SimulatorLocationCoordinate(
                    latitude: start.latitude + ((end.latitude - start.latitude) * progress),
                    longitude: start.longitude + ((end.longitude - start.longitude) * progress)
                )
                return SimulatorLocationRoute(
                    waypoints: [current] + Array(points[(index + 1)...]),
                    speed: route.speed,
                    updateDistance: route.updateDistance,
                    updateInterval: route.updateInterval,
                    loops: false
                )
            }
            remainingDistance -= segmentDistance
        }
        return SimulatorLocationRoute(
            waypoints: [finalPoint],
            speed: route.speed,
            updateDistance: route.updateDistance,
            updateInterval: route.updateInterval,
            loops: false
        )
    }

    func commandWaypoints(
        for route: SimulatorLocationRoute
    ) -> [SimulatorLocationCoordinate] {
        guard route.loops,
              let first = route.waypoints.first,
              route.waypoints.last != first else { return route.waypoints }
        return route.waypoints + [first]
    }

    func routeDuration(_ route: SimulatorLocationRoute) -> TimeInterval? {
        route.estimatedDuration
    }

    func remainingLoopingRoute(
        _ route: SimulatorLocationRoute,
        after elapsed: TimeInterval
    ) -> SimulatorLocationRoute {
        var points = route.waypoints
        if points.first == points.last { points.removeLast() }
        guard points.count >= 2 else { return route }
        let segments = points.indices.map { index in
            (points[index], points[(index + 1) % points.count])
        }
        let totalDistance = segments.reduce(0) {
            $0 + distance(from: $1.0, to: $1.1)
        }
        guard totalDistance > 0 else { return route }
        var remainingDistance = (max(0, elapsed) * route.speed)
            .truncatingRemainder(dividingBy: totalDistance)
        for index in segments.indices {
            let segment = segments[index]
            let segmentDistance = distance(from: segment.0, to: segment.1)
            if remainingDistance < segmentDistance, segmentDistance > 0 {
                let progress = remainingDistance / segmentDistance
                let current = SimulatorLocationCoordinate(
                    latitude: segment.0.latitude
                        + ((segment.1.latitude - segment.0.latitude) * progress),
                    longitude: segment.0.longitude
                        + ((segment.1.longitude - segment.0.longitude) * progress)
                )
                let rotated = (1...points.count).map { offset in
                    points[(index + offset) % points.count]
                }
                return SimulatorLocationRoute(
                    waypoints: [current] + rotated,
                    speed: route.speed,
                    updateDistance: route.updateDistance,
                    updateInterval: route.updateInterval,
                    loops: true
                )
            }
            remainingDistance -= segmentDistance
        }
        return route
    }

    private func scheduleLocationLifecycle(
        deviceID: String,
        route: SimulatorLocationRoute,
        token: UUID,
        durationOverride: TimeInterval? = nil
    ) {
        cancelLocationLifecycle(deviceID: deviceID)
        guard locationRouteTokens[deviceID] == token,
              let duration = durationOverride ?? routeDuration(route) else { return }
        let routeSleep = routeSleep
        locationLifecycleTasks[deviceID] = Task { [weak self] in
            do {
                try await routeSleep(.seconds(duration))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if route.loops {
                await self?.restartLocationLoop(deviceID: deviceID, route: route, token: token)
            } else {
                await self?.completeLocationRoute(deviceID: deviceID, route: route, token: token)
            }
        }
    }

    private func completeLocationRoute(
        deviceID: String,
        route: SimulatorLocationRoute,
        token: UUID
    ) {
        guard locationRouteTokens[deviceID] == token,
              case let .running(activeRoute, _) = activeLocationRoutes[deviceID],
              activeRoute == route else { return }
        locationLifecycleTasks.removeValue(forKey: deviceID)
        locationRouteTokens.removeValue(forKey: deviceID)
        activeLocationRoutes.removeValue(forKey: deviceID)
    }

    private func restartLocationLoop(
        deviceID: String,
        route: SimulatorLocationRoute,
        token: UUID
    ) async {
        do {
            try await mutationGate.withLocks([.location(deviceIdentifier: deviceID)]) {
                guard !Task.isCancelled,
                      locationRouteTokens[deviceID] == token,
                      case let .running(activeRoute, _) = activeLocationRoutes[deviceID],
                      activeRoute == route else { return }
                try await runLocationRouteCommand(deviceID: deviceID, route: route)
                guard !Task.isCancelled,
                      locationRouteTokens[deviceID] == token,
                      case let .running(currentRoute, _) = activeLocationRoutes[deviceID],
                      currentRoute == route else { return }
                activeLocationRoutes[deviceID] = .running(route: route, startedAt: now())
                scheduleLocationLifecycle(deviceID: deviceID, route: route, token: token)
            }
        } catch {
            guard locationRouteTokens[deviceID] == token else { return }
            cancelLocationLifecycle(deviceID: deviceID)
            locationRouteTokens.removeValue(forKey: deviceID)
            if case let .running(currentRoute, _) = activeLocationRoutes[deviceID],
               currentRoute == route {
                activeLocationRoutes.removeValue(forKey: deviceID)
            }
        }
    }

    private func beginLocationOperation(deviceID: String) -> UUID {
        cancelLocationLifecycle(deviceID: deviceID)
        let token = UUID()
        locationRouteTokens[deviceID] = token
        return token
    }

    private func finishLocationOperation(deviceID: String, token: UUID) {
        guard locationRouteTokens[deviceID] == token else { return }
        locationRouteTokens.removeValue(forKey: deviceID)
    }

    private func requireCurrentLocationOperation(deviceID: String, token: UUID) throws {
        guard locationRouteTokens[deviceID] == token else { throw CancellationError() }
    }

    private func cancelLocationLifecycle(deviceID: String) {
        locationLifecycleTasks.removeValue(forKey: deviceID)?.cancel()
    }

    func distance(
        from start: SimulatorLocationCoordinate,
        to end: SimulatorLocationCoordinate
    ) -> Double {
        let earthRadius = 6_371_000.0
        let latitude1 = start.latitude * .pi / 180
        let latitude2 = end.latitude * .pi / 180
        let latitudeDelta = (end.latitude - start.latitude) * .pi / 180
        let longitudeDelta = (end.longitude - start.longitude) * .pi / 180
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(latitude1) * cos(latitude2)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

}
